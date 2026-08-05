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

    private let ocr: VisionOCRService
    private let tuning: Tuning
    private var handler: Handler?
    private var frameQueue: [CapturedScreenFrame] = []
    private var drainTask: Task<Void, Never>?
    private var quietFlushTask: Task<Void, Never>?
    private var pendingBatch: PendingBatch?
    private var recentEmissions: [ContextKey: Emission] = [:]

    init(ocr: VisionOCRService = VisionOCRService(), tuning: Tuning = Tuning()) {
        self.ocr = ocr
        self.tuning = tuning
    }

    func start(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Submission never waits for OCR or network work. When capture is faster than
    /// local processing, retain only the newest bounded set of frames.
    func submit(_ frame: CapturedScreenFrame) {
        frameQueue.append(frame)
        if frameQueue.count > tuning.maximumPendingFrames {
            frameQueue.removeFirst(frameQueue.count - tuning.maximumPendingFrames)
        }
        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in
            await self?.drain()
        }
    }

    func cancel() {
        frameQueue.removeAll(keepingCapacity: true)
        quietFlushTask?.cancel()
        quietFlushTask = nil
        pendingBatch = nil
    }

    func flush() async {
        await emitPendingBatch()
    }

    private func drain() async {
        while !Task.isCancelled {
            guard !frameQueue.isEmpty else {
                drainTask = nil
                return
            }
            let frame = frameQueue.removeFirst()
            do {
                let text = ExclusionPolicy.redactSensitiveText(try await ocr.recognizeText(in: frame.image))
                await incorporate(frame: frame, text: text)
            } catch {
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
            await emitPendingBatch()
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
        } else {
            pendingBatch?.context = frame.context
            pendingBatch?.latestAt = frame.capturedAt
            pendingBatch?.jpegData = frame.jpegData
            pendingBatch?.contentFingerprint = frame.signature.digest
            pendingBatch?.containsHighRiskSignal = pendingBatch?.containsHighRiskSignal == true || isHighRisk
            if !normalized.isEmpty, pendingBatch?.normalizedTexts.contains(normalized) == false {
                pendingBatch?.normalizedTexts.insert(normalized)
                pendingBatch?.distinctTexts.append(text)
            }
        }

        guard let batch = pendingBatch else { return }
        if batch.containsHighRiskSignal || frame.capturedAt.timeIntervalSince(batch.startedAt) >= tuning.hardFlushInterval {
            await emitPendingBatch()
        } else {
            scheduleQuietFlush(generation: batch.generation)
        }
    }

    private func scheduleQuietFlush(generation: UUID) {
        quietFlushTask?.cancel()
        let delay = tuning.quietInterval
        quietFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.flushIfCurrent(generation: generation)
        }
    }

    private func flushIfCurrent(generation: UUID) async {
        guard pendingBatch?.generation == generation else { return }
        await emitPendingBatch()
    }

    private func emitPendingBatch() async {
        guard let batch = pendingBatch else { return }
        pendingBatch = nil
        quietFlushTask?.cancel()
        quietFlushTask = nil

        let text = Self.joinedText(batch.distinctTexts, limit: tuning.maximumTextCharacters)
        let fingerprint = Self.textFingerprint(text)
        let now = batch.latestAt
        recentEmissions = recentEmissions.filter { now.timeIntervalSince($0.value.emittedAt) < tuning.duplicateWindow }
        if !text.isEmpty,
           let previous = recentEmissions[batch.key],
           previous.fingerprint == fingerprint,
           now.timeIntervalSince(previous.emittedAt) < tuning.duplicateWindow {
            return
        }
        recentEmissions[batch.key] = Emission(fingerprint: fingerprint, emittedAt: now)
        await handler?(BatchedScreenObservation(
            context: batch.context,
            capturedAt: batch.latestAt,
            jpegData: batch.jpegData,
            contentFingerprint: batch.contentFingerprint,
            text: text,
            containsHighRiskSignal: batch.containsHighRiskSignal
        ))
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

    nonisolated static func containsHighRiskSignal(text: String, context: ActiveContext) -> Bool {
        if context.isMeeting { return true }
        let normalized = ScreenObservationBatcher.normalizedText(
            [text, context.windowTitle, context.url?.absoluteString].compactMap { $0 }.joined(separator: " ")
        )
        if phrases.contains(where: normalized.contains) { return true }
        return normalized.range(
            of: #"\b(?:today|tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday|aujourd'hui|demain|lundi|mardi|mercredi|jeudi|vendredi|samedi|dimanche|\d{1,2}[/:.-]\d{1,2}(?:[/:.-]\d{2,4})?|\d{1,2}:\d{2})\b"#,
            options: .regularExpression
        ) != nil
    }
}
