@preconcurrency import AppKit
import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

struct CapturedScreenFrame: @unchecked Sendable {
    var image: CGImage
    var jpegData: Data
    var signature: FrameSignature
    var context: ActiveContext
    var capturedAt: Date
    var significantChange: Bool
}

actor ScreenCaptureService {
    typealias Handler = @Sendable (CapturedScreenFrame) async -> Void
    typealias VisibilityHandler = @Sendable (ScreenContextVisibility) async -> Void
    typealias FailureHandler = @Sendable (String?) async -> Void

    private let contextService: ActiveContextService
    private var captureTask: Task<Void, Never>?
    private var dispatcher: BoundedAsyncDispatcher<CapturedScreenFrame>?
    private var capturePolicy = AdaptiveCapturePolicy()
    private var legacyCapturePolicy = LegacyCapturePolicy()

    init(contextService: ActiveContextService = ActiveContextService()) {
        self.contextService = contextService
    }

    func start(
        settingsProvider: @escaping @Sendable () async -> IrizSettings,
        visibilityHandler: @escaping VisibilityHandler = { _ in },
        failureHandler: @escaping FailureHandler = { _ in },
        telemetryHandler: @escaping OptimizationTelemetryHandler = { _ in },
        handler: @escaping Handler
    ) {
        guard captureTask == nil else { return }
        let dispatcher = BoundedAsyncDispatcher<CapturedScreenFrame>(capacity: 3) { [weak self] frame in
            guard let self else { return }
            await self.recordDispatched(frame)
            await telemetryHandler(OptimizationTelemetryRecord(
                occurredAt: frame.capturedAt,
                metric: .captureDelivered,
                source: .screen,
                isMeeting: frame.context.isMeeting
            ))
            await handler(frame)
        }
        self.dispatcher = dispatcher
        captureTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let settings = await settingsProvider()
                if Self.shouldAttemptCapture(
                    settings: settings,
                    permission: PermissionService.screenCaptureState(),
                    accessibilityPermission: PermissionService.accessibilityState()
                ) {
                    await telemetryHandler(OptimizationTelemetryRecord(metric: .captureAttempted, source: .screen))
                    do {
                        try await self.captureOne(
                            settings: settings,
                            visibilityHandler: visibilityHandler,
                            dispatcher: dispatcher,
                            telemetryHandler: telemetryHandler,
                            handler: handler
                        )
                        await failureHandler(nil)
                    } catch {
                        await self.resetCapturePolicy()
                        await telemetryHandler(OptimizationTelemetryRecord(
                            metric: .captureFailed,
                            reason: .captureError,
                            source: .screen
                        ))
                        await self.invalidatePendingFrames()
                        await failureHandler("Screen observation is unavailable.")
                        await visibilityHandler(.unavailable)
                        // Retry quietly. Only the explicit Allow button may open a system prompt.
                    }
                } else {
                    await self.invalidatePendingFrames()
                    await telemetryHandler(OptimizationTelemetryRecord(
                        metric: .captureUnavailable,
                        reason: settings.isScreenCaptureActiveNow
                            ? .permissionUnavailable
                            : .pauseOrPrivateContext,
                        source: .screen
                    ))
                    await failureHandler(nil)
                    await visibilityHandler(.unavailable)
                }
                let interval = await self.nextCaptureInterval(for: settings.optimizationPhase)
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() async {
        let task = captureTask
        task?.cancel()
        captureTask = nil
        await task?.value
        await dispatcher?.cancelPendingAndWait()
        resetCapturePolicy()
        dispatcher = nil
    }

    /// Invalidates both capture baselines and every frame that has not crossed
    /// the privacy boundary yet. The dispatcher remains reusable when capture
    /// later resumes in an allowed context.
    func invalidatePendingFrames() async {
        await dispatcher?.cancelPending()
        resetCapturePolicy()
    }

    /// Privacy-boundary variant that also fences the currently executing
    /// dispatcher handler before the caller purges batches or durable jobs.
    func invalidatePendingFramesAndWait() async {
        await dispatcher?.cancelPendingAndWait()
        resetCapturePolicy()
    }

    nonisolated static func shouldAttemptCapture(
        settings: IrizSettings,
        permission: PermissionState,
        accessibilityPermission: PermissionState = .granted
    ) -> Bool {
        settings.isScreenCaptureActiveNow
            && permission == .granted
            && accessibilityPermission == .granted
    }

    private func captureOne(
        settings: IrizSettings,
        visibilityHandler: @escaping VisibilityHandler,
        dispatcher: BoundedAsyncDispatcher<CapturedScreenFrame>,
        telemetryHandler: @escaping OptimizationTelemetryHandler,
        handler: @escaping Handler
    ) async throws {
        let outcome = await contextService.current(settings: settings)
        if outcome.visibility != .available {
            // Purge before notifying the app so an older visible frame cannot
            // be delivered while the private/unavailable transition is handled.
            await dispatcher.cancelPending()
        }
        await visibilityHandler(outcome.visibility)
        guard let context = outcome.capturableContext else {
            capturePolicy.reset()
            await telemetryHandler(OptimizationTelemetryRecord(
                metric: .captureContextUnavailable,
                reason: .unavailableContext,
                source: .screen
            ))
            return
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard await revalidate(
            expected: context,
            settings: settings,
            visibilityHandler: visibilityHandler,
            dispatcher: dispatcher,
            telemetryHandler: telemetryHandler
        ) else { return }
        guard let window = Self.activeWindow(for: context, in: content.windows) else {
            await dispatcher.cancelPending()
            resetCapturePolicy()
            await telemetryHandler(OptimizationTelemetryRecord(
                metric: .captureContextUnavailable,
                reason: .unavailableContext,
                source: .screen,
                isMeeting: context.isMeeting
            ))
            return
        }
        // Privacy boundary: capture only the focused window whose AX context was
        // qualified above. A display-wide filter can expose another window from
        // the same app (for example, a private Chrome tab beside the active one).
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let sourceWidth = max(Int(window.frame.width.rounded(.up)), 1)
        let sourceHeight = max(Int(window.frame.height.rounded(.up)), 1)
        let maximumWidth = min(sourceWidth, 1440)
        let scale = Double(maximumWidth) / Double(sourceWidth)
        configuration.width = maximumWidth
        configuration.height = max(Int(Double(sourceHeight) * scale), 1)
        configuration.showsCursor = true
        configuration.capturesAudio = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard await revalidate(
            expected: context,
            settings: settings,
            visibilityHandler: visibilityHandler,
            dispatcher: dispatcher,
            telemetryHandler: telemetryHandler
        ) else { return }
        guard let signature = FrameDiffer.signature(for: image) else { return }
        let significant: Bool
        if settings.optimizationPhase == .legacy {
            significant = legacyCapturePolicy.register(signature: signature, context: context)
        } else {
            significant = capturePolicy.shouldDeliver(signature: signature, context: context)
        }
        guard significant else {
            if settings.optimizationPhase != .legacy {
                capturePolicy.recordStableSample()
            }
            await telemetryHandler(OptimizationTelemetryRecord(
                metric: .captureStableSkipped,
                reason: .unchangedFrame,
                source: .screen,
                isMeeting: context.isMeeting
            ))
            return
        }
        guard let jpeg = Self.jpegData(from: image, quality: 0.68) else { return }
        let now = Date()
        let frame = CapturedScreenFrame(
            image: image,
            jpegData: jpeg,
            signature: signature,
            context: context,
            capturedAt: now,
            significantChange: significant
        )
        if settings.optimizationPhase == .legacy {
            await telemetryHandler(OptimizationTelemetryRecord(
                occurredAt: now,
                metric: .captureDelivered,
                source: .screen,
                isMeeting: context.isMeeting
            ))
            await handler(frame)
            return
        }
        capturePolicy.recordPendingDelivery()
        let submission = await dispatcher.submit(frame)
        if submission.droppedCount > 0 {
            await telemetryHandler(OptimizationTelemetryRecord(
                metric: .captureQueueDropped,
                reason: .queueCapacity,
                source: .screen,
                occurrenceCount: submission.droppedCount,
                queueDepth: submission.pendingDepth,
                isMeeting: context.isMeeting
            ))
        }
    }

    /// ScreenCaptureKit awaits can span an app, URL, or secure-field switch.
    /// Re-read accessibility context after each await and drop the entire old
    /// capture generation unless it still describes the same allowed window.
    private func revalidate(
        expected context: ActiveContext,
        settings: IrizSettings,
        visibilityHandler: @escaping VisibilityHandler,
        dispatcher: BoundedAsyncDispatcher<CapturedScreenFrame>,
        telemetryHandler: @escaping OptimizationTelemetryHandler
    ) async -> Bool {
        let outcome = await contextService.current(settings: settings)
        await visibilityHandler(outcome.visibility)
        guard Self.contextMatches(expected: context, outcome: outcome) else {
            await dispatcher.cancelPending()
            resetCapturePolicy()
            await telemetryHandler(OptimizationTelemetryRecord(
                metric: .captureContextUnavailable,
                reason: outcome.visibility == .available ? .contextChanged : .pauseOrPrivateContext,
                source: .screen,
                isMeeting: context.isMeeting
            ))
            return false
        }
        return !Task.isCancelled
    }

    nonisolated static func contextMatches(
        expected: ActiveContext,
        outcome: ActiveContextOutcome
    ) -> Bool {
        outcome.capturableContext == expected
    }

    private func nextCaptureInterval(for phase: OptimizationPhase) -> Duration {
        phase == .legacy ? .seconds(2) : capturePolicy.nextInterval
    }

    private func recordDispatched(_ frame: CapturedScreenFrame) {
        capturePolicy.recordDelivered(signature: frame.signature, context: frame.context)
    }

    private func resetCapturePolicy() {
        capturePolicy.reset()
        legacyCapturePolicy.reset()
    }

    nonisolated static func activeWindow(for context: ActiveContext, in windows: [SCWindow]) -> SCWindow? {
        let candidates = windows.filter { window in
            guard window.isOnScreen,
                  window.frame.width > 0,
                  window.frame.height > 0 else { return false }
            if let processIdentifier = context.processIdentifier {
                return window.owningApplication?.processID == processIdentifier
            }
            guard let expectedBundle = context.bundleIdentifier else { return false }
            return window.owningApplication?.bundleIdentifier == expectedBundle
        }
        guard !candidates.isEmpty else { return nil }

        let expectedTitle = context.windowTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let titleMatches = expectedTitle.map { title in
            candidates.filter {
                $0.title?.trimmingCharacters(in: .whitespacesAndNewlines) == title
            }
        } ?? []
        let pool = titleMatches.isEmpty ? candidates : titleMatches
        if let expectedFrame = context.windowFrame {
            return pool.min { lhs, rhs in
                frameDistance(lhs.frame, expectedFrame) < frameDistance(rhs.frame, expectedFrame)
            }
        }
        // When AX cannot expose bounds, prefer the sole exact-title match. More
        // than one ambiguous window fails closed instead of risking disclosure.
        guard pool.count == 1 else { return nil }
        return pool[0]
    }

    nonisolated private static func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.minX - rhs.minX)
            + abs(lhs.minY - rhs.minY)
            + abs(lhs.width - rhs.width)
            + abs(lhs.height - rhs.height)
    }

    private static func jpegData(from image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
