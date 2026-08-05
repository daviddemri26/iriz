import CryptoKit
import Foundation

struct BatchedScreenObservation: @unchecked Sendable {
    var context: ActiveContext
    var capturedAt: Date
    var jpegData: Data
    var contentFingerprint: String
    var text: String
    var containsHighRiskSignal: Bool
}

actor ScreenObservationBatcher {
    typealias Handler = @Sendable (BatchedScreenObservation) async -> Void

    struct Tuning: Equatable, Sendable {
        var quietInterval: TimeInterval = 10
        var hardFlushInterval: TimeInterval = 30
        var duplicateWindow: TimeInterval = 15 * 60
        var maximumPendingFrames = 3
        var maximumTextCharacters = 12_000
    }

    private struct ContextKey: Hashable, Sendable {
        var bundleIdentifier: String
        var windowTitle: String
        var host: String
    }

    private struct PendingBatch: @unchecked Sendable {
        var key: ContextKey
        var context: ActiveContext
        var startedAt: Date
        var latestAt: Date
        var jpegData: Data
        var contentFingerprint: String
        var distinctTexts: [String]
        var normalizedTexts: Set<String>
        var containsHighRiskSignal: Bool
        var generation: UUID
    }

    private struct Emission: Sendable {
        var fingerprint: String
        var emittedAt: Date
    }

    private let ocr: any ScreenOCRProviding
    private let tuning: Tuning
    private var handler: Handler?
    private var telemetryHandler: OptimizationTelemetryHandler?
    private var frameQueue: [CapturedScreenFrame] = []
    private var drainTask: Task<Void, Never>?
    private var quietFlushTask: Task<Void, Never>?
    private var pendingBatch: PendingBatch?
    private var recentEmissions: [ContextKey: Emission] = [:]
    private var emissionTasks: [UUID: Task<Void, Never>] = [:]
    private var cancellationGeneration = 0

    init(ocr: any ScreenOCRProviding = VisionOCRService(), tuning: Tuning = Tuning()) {
        self.ocr = ocr
        self.tuning = tuning
    }

    func start(
        telemetryHandler: OptimizationTelemetryHandler? = nil,
        handler: @escaping Handler
    ) {
        self.handler = handler
        self.telemetryHandler = telemetryHandler
    }

    /// Submission never waits for OCR or network work. When capture is faster than
    /// local processing, retain only the newest bounded set of frames.
    func submit(_ frame: CapturedScreenFrame) async {
        let submissionGeneration = cancellationGeneration
        let overflow = max(0, frameQueue.count + 1 - tuning.maximumPendingFrames)
        frameQueue.append(frame)
        if frameQueue.count > tuning.maximumPendingFrames {
            frameQueue.removeFirst(frameQueue.count - tuning.maximumPendingFrames)
        }
        let currentDepth = frameQueue.count
        await telemetryHandler?(OptimizationTelemetryRecord(
            occurredAt: frame.capturedAt,
            metric: .batchFrameAccepted,
            source: .screen,
            queueDepth: currentDepth,
            isMeeting: frame.context.isMeeting
        ))
        if overflow > 0 {
            await telemetryHandler?(OptimizationTelemetryRecord(
                occurredAt: frame.capturedAt,
                metric: .batchFrameDropped,
                reason: .queueCapacity,
                source: .screen,
                occurrenceCount: overflow,
                queueDepth: currentDepth,
                isMeeting: frame.context.isMeeting
            ))
        }
        guard !Task.isCancelled,
              cancellationGeneration == submissionGeneration else { return }
        guard drainTask == nil else { return }
        let activeGeneration = cancellationGeneration
        drainTask = Task { [weak self] in
            await self?.drain(generation: activeGeneration)
        }
    }

    func cancel() async {
        let discardedCount = frameQueue.count + (pendingBatch == nil ? 0 : 1)
        cancellationGeneration += 1
        frameQueue.removeAll(keepingCapacity: true)
        drainTask?.cancel()
        drainTask = nil
        quietFlushTask?.cancel()
        quietFlushTask = nil
        pendingBatch = nil
        // An emission handler may have been cancelled after its fingerprint was
        // recorded but before durable persistence. Do not suppress the first
        // identical screen after a privacy/pause boundary as "already sent".
        recentEmissions.removeAll(keepingCapacity: true)
        emissionTasks.values.forEach { $0.cancel() }
        if discardedCount > 0 {
            await telemetryHandler?(OptimizationTelemetryRecord(
                metric: .batchCancelled,
                reason: .pauseOrPrivateContext,
                source: .screen,
                occurrenceCount: discardedCount
            ))
        }
    }

    func cancelAndDrain() async {
        // Capture every producer before `cancel()` clears the actor properties.
        // Both tasks may currently be suspended in OCR/telemetry and can otherwise
        // resume after an apparently completed privacy boundary.
        let activeDrainTask = drainTask
        let activeQuietFlushTask = quietFlushTask
        await cancel()
        await activeDrainTask?.value
        await activeQuietFlushTask?.value

        // A handler that was registered immediately before cancellation remains
        // visible here. Re-snapshot until the actor has removed every completed
        // emission; this makes the fence robust to actor reentrancy.
        while !emissionTasks.isEmpty {
            let tasks = emissionTasks
            for (identifier, task) in tasks {
                await task.value
                // `emitPendingBatch` also removes this entry. Removing it here is
                // idempotent and avoids a tight actor loop starving that continuation.
                emissionTasks.removeValue(forKey: identifier)
            }
        }
    }

    func drainEmissions() async {
        let tasks = Array(emissionTasks.values)
        for task in tasks { await task.value }
    }

    #if DEBUG
    func cancellationGenerationForTesting() -> Int {
        cancellationGeneration
    }
    #endif

    func flush() async {
        await emitPendingBatch(reason: .quietInterval)
    }

    private func drain(generation activeGeneration: Int) async {
        while !Task.isCancelled, cancellationGeneration == activeGeneration {
            guard !frameQueue.isEmpty else {
                drainTask = nil
                return
            }
            let frame = frameQueue.removeFirst()
            do {
                let text = ExclusionPolicy.redactSensitiveText(try await ocr.recognizeText(in: frame.image))
                guard !Task.isCancelled, cancellationGeneration == activeGeneration else { return }
                await incorporate(frame: frame, text: text)
            } catch {
                guard !Task.isCancelled, cancellationGeneration == activeGeneration else { return }
                // OCR failure is fail-open: retain the image and empty text so Luna
                // can still inspect the representative frame.
                await incorporate(frame: frame, text: "")
            }
        }
    }

    private func incorporate(frame: CapturedScreenFrame, text: String) async {
        let key = Self.contextKey(for: frame.context)
        let normalized = Self.normalizedText(text)
        let isHighRisk = ObservationRiskSignals.containsHighRiskSignal(
            text: text,
            context: frame.context
        )

        if let current = pendingBatch, current.key != key {
            await emitPendingBatch(reason: .contextChanged)
        }

        if pendingBatch == nil {
            pendingBatch = PendingBatch(
                key: key,
                context: frame.context,
                startedAt: frame.capturedAt,
                latestAt: frame.capturedAt,
                jpegData: frame.jpegData,
                contentFingerprint: frame.signature.digest,
                distinctTexts: normalized.isEmpty ? [] : [text],
                normalizedTexts: normalized.isEmpty ? [] : [normalized],
                containsHighRiskSignal: isHighRisk,
                generation: UUID()
            )
        } else if var current = pendingBatch {
            // Mutate one local value and write it back once. Reading and modifying
            // the same optional-chained actor property in one expression can trip
            // Swift's dynamic exclusivity checks under concurrent test load.
            current.context = frame.context
            current.latestAt = frame.capturedAt
            current.jpegData = frame.jpegData
            current.contentFingerprint = frame.signature.digest
            current.containsHighRiskSignal = current.containsHighRiskSignal || isHighRisk
            if !normalized.isEmpty, !current.normalizedTexts.contains(normalized) {
                current.normalizedTexts.insert(normalized)
                current.distinctTexts.append(text)
            }
            pendingBatch = current
        }

        guard let batch = pendingBatch else { return }
        if batch.containsHighRiskSignal || frame.capturedAt.timeIntervalSince(batch.startedAt) >= tuning.hardFlushInterval {
            await emitPendingBatch(
                reason: batch.containsHighRiskSignal ? .highRiskSignal : .hardDeadline
            )
        } else {
            scheduleQuietFlush(generation: batch.generation)
        }
    }

    private func scheduleQuietFlush(generation: UUID) {
        quietFlushTask?.cancel()
        guard let batch = pendingBatch, batch.generation == generation else {
            quietFlushTask = nil
            return
        }
        let quietDeadline = batch.latestAt.addingTimeInterval(tuning.quietInterval)
        let hardDeadline = batch.startedAt.addingTimeInterval(tuning.hardFlushInterval)
        let deadline = min(quietDeadline, hardDeadline)
        let reason: OptimizationTelemetryReason = hardDeadline <= quietDeadline
            ? .hardDeadline
            : .quietInterval
        let delay = max(deadline.timeIntervalSinceNow, 0)
        quietFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.flushIfCurrent(generation: generation, reason: reason)
        }
    }

    private func flushIfCurrent(
        generation: UUID,
        reason: OptimizationTelemetryReason = .quietInterval
    ) async {
        guard pendingBatch?.generation == generation else { return }
        await emitPendingBatch(reason: reason)
    }

    private func emitPendingBatch(reason: OptimizationTelemetryReason) async {
        guard let batch = pendingBatch else { return }
        let activeCancellationGeneration = cancellationGeneration
        pendingBatch = nil
        quietFlushTask?.cancel()
        quietFlushTask = nil

        let text = Self.joinedText(batch.distinctTexts, limit: tuning.maximumTextCharacters)
        let fingerprint = Self.textFingerprint(text)
        let now = Date()
        let latencyEnd = max(now, batch.latestAt)
        recentEmissions = recentEmissions.filter { now.timeIntervalSince($0.value.emittedAt) < tuning.duplicateWindow }
        if !text.isEmpty,
           let previous = recentEmissions[batch.key],
           previous.fingerprint == fingerprint,
           now.timeIntervalSince(previous.emittedAt) < tuning.duplicateWindow {
            await telemetryHandler?(OptimizationTelemetryRecord(
                occurredAt: now,
                metric: .batchSuppressedDuplicate,
                reason: .duplicateOCR,
                source: .screen,
                latencyMilliseconds: Self.milliseconds(between: batch.startedAt, and: latencyEnd),
                isMeeting: batch.context.isMeeting
            ))
            return
        }
        await telemetryHandler?(OptimizationTelemetryRecord(
            occurredAt: now,
            metric: .batchEmitted,
            reason: reason,
            source: .screen,
            latencyMilliseconds: Self.milliseconds(between: batch.startedAt, and: latencyEnd),
            isMeeting: batch.context.isMeeting
        ))
        // Telemetry is an actor-reentrancy point. A privacy cancellation may have
        // happened while it was persisted, so never create a late handler task for
        // content from the previous generation.
        // The quiet-flush task deliberately cancels its own stored timer while
        // emitting. Generation, rather than Task cancellation alone, identifies
        // an actual privacy-boundary cancellation here.
        guard cancellationGeneration == activeCancellationGeneration else { return }
        recentEmissions[batch.key] = Emission(fingerprint: fingerprint, emittedAt: now)
        let output = BatchedScreenObservation(
            context: batch.context,
            // The visibility SLA starts at the first meaningful change, not at
            // the last sample that happened to reset the debounce timer.
            capturedAt: batch.startedAt,
            jpegData: batch.jpegData,
            contentFingerprint: batch.contentFingerprint,
            text: text,
            containsHighRiskSignal: batch.containsHighRiskSignal
        )
        guard let handler else { return }
        let identifier = UUID()
        let task = Task { await handler(output) }
        emissionTasks[identifier] = task
        await task.value
        emissionTasks.removeValue(forKey: identifier)
    }

    nonisolated static func normalizedText(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    nonisolated static func joinedText(_ values: [String], limit: Int) -> String {
        guard limit > 0 else { return "" }
        var result = ""
        for value in values {
            let separator = result.isEmpty ? "" : "\n---\n"
            let available = limit - result.count - separator.count
            guard available > 0 else { break }
            result += separator + String(value.prefix(available))
        }
        return result
    }

    private nonisolated static func contextKey(for context: ActiveContext) -> ContextKey {
        ContextKey(
            bundleIdentifier: context.bundleIdentifier?.lowercased() ?? "",
            windowTitle: normalizedText(context.windowTitle ?? ""),
            host: context.url?.host()?.lowercased() ?? ""
        )
    }

    private nonisolated static func textFingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(normalizedText(text).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func milliseconds(between start: Date, and end: Date) -> Int {
        Int(max(0, end.timeIntervalSince(start)) * 1_000)
    }
}

enum ObservationRiskSignals {
    private static let phrases = [
        "confirmed", "confirmation", "completed", "complete", "submitted", "sent",
        "approved", "accepted", "purchased", "ordered", "paid", "payment", "receipt",
        "deadline", "due date", "appointment", "reservation", "booking", "decision",
        "engagement", "commitment", "promised", "will send", "i will", "i'll",
        "confirmé", "confirmation", "terminé", "terminée", "envoyé", "envoyée",
        "soumis", "soumise", "approuvé", "accepté", "acheté", "commande", "paiement",
        "échéance", "rendez-vous", "réservation", "décision", "je vais", "je m'engage"
    ]
    private static let deadlinePhrases = [
        "deadline", "due date", "due by", "by end of", "appointment", "reservation",
        "échéance", "date limite", "pour le", "avant le", "rendez-vous", "réservation"
    ]

    nonisolated static func containsHighRiskSignal(text: String, context: ActiveContext) -> Bool {
        if context.isMeeting { return true }
        let normalized = ScreenObservationBatcher.normalizedText(
            [text, context.windowTitle, context.url?.absoluteString].compactMap { $0 }.joined(separator: " ")
        )
        if phrases.contains(where: normalized.contains) { return true }
        return containsDeadlineSignal(normalizedText: normalized)
    }

    nonisolated static func containsDeadlineSignal(text: String, context: ActiveContext) -> Bool {
        let normalized = ScreenObservationBatcher.normalizedText(
            [text, context.windowTitle, context.url?.absoluteString].compactMap { $0 }.joined(separator: " ")
        )
        return containsDeadlineSignal(normalizedText: normalized)
    }

    private nonisolated static func containsDeadlineSignal(normalizedText normalized: String) -> Bool {
        if deadlinePhrases.contains(where: normalized.contains) { return true }
        return normalized.range(
            of: #"\b(?:today|tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday|aujourd'hui|demain|lundi|mardi|mercredi|jeudi|vendredi|samedi|dimanche|\d{1,2}[/:.-]\d{1,2}(?:[/:.-]\d{2,4})?|\d{1,2}:\d{2})\b"#,
            options: .regularExpression
        ) != nil
    }
}
