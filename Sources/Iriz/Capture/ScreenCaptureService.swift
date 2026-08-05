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
    private var previousSignature: FrameSignature?
    private var previousContext: ActiveContext?
    private var lastDeliveredAt = Date.distantPast

    init(contextService: ActiveContextService = ActiveContextService()) {
        self.contextService = contextService
    }

    func start(
        settingsProvider: @escaping @Sendable () async -> IrizSettings,
        visibilityHandler: @escaping VisibilityHandler = { _ in },
        failureHandler: @escaping FailureHandler = { _ in },
        handler: @escaping Handler
    ) {
        guard captureTask == nil else { return }
        captureTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let settings = await settingsProvider()
                if Self.shouldAttemptCapture(
                    settings: settings,
                    permission: PermissionService.screenCaptureState(),
                    accessibilityPermission: PermissionService.accessibilityState()
                ) {
                    do {
                        try await self.captureOne(
                            settings: settings,
                            visibilityHandler: visibilityHandler,
                            handler: handler
                        )
                        await failureHandler(nil)
                    } catch {
                        await failureHandler("Screen observation is unavailable.")
                        await visibilityHandler(.unavailable)
                        // Retry quietly. Only the explicit Allow button may open a system prompt.
                    }
                } else {
                    await failureHandler(nil)
                    await visibilityHandler(.unavailable)
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        captureTask?.cancel()
        captureTask = nil
        previousSignature = nil
        previousContext = nil
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
        handler: @escaping Handler
    ) async throws {
        let outcome = await contextService.current(settings: settings)
        await visibilityHandler(outcome.visibility)
        guard let context = outcome.capturableContext else { return }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = activeDisplay(in: content.displays) else { return }
        let excludedApplications = content.applications.filter { application in
            let id = application.bundleIdentifier
            return settings.excludedBundleIdentifiers.contains(id) || id == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(display: display, excludingApplications: excludedApplications, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        let maximumWidth = min(Int(display.width), 1440)
        let scale = Double(maximumWidth) / Double(max(Int(display.width), 1))
        configuration.width = maximumWidth
        configuration.height = max(Int(Double(display.height) * scale), 1)
        configuration.showsCursor = true
        configuration.capturesAudio = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let signature = FrameDiffer.signature(for: image),
              let jpeg = Self.jpegData(from: image, quality: 0.68) else { return }
        let difference = FrameDiffer.difference(from: previousSignature, to: signature)
        let contextChanged = context != previousContext
        let now = Date()
        let significant = difference >= 0.075 || contextChanged
        previousSignature = signature
        previousContext = context
        guard significant else { return }
        lastDeliveredAt = now
        await handler(CapturedScreenFrame(
            image: image,
            jpegData: jpeg,
            signature: signature,
            context: context,
            capturedAt: now,
            significantChange: significant
        ))
    }

    private func activeDisplay(in displays: [SCDisplay]) -> SCDisplay? {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        let id = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        return displays.first(where: { $0.displayID == id }) ?? displays.first
    }

    private static func jpegData(from image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
