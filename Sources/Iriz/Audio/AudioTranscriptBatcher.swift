import Foundation

struct AudioTranscriptInput: Sendable {
    var observationID: UUID
    var source: ObservationSource
    var capturedAt: Date
    var context: ActiveContext
    var text: String
    var audioDuration: TimeInterval

    init(
        observationID: UUID,
        source: ObservationSource,
        capturedAt: Date,
        context: ActiveContext,
        text: String,
        audioDuration: TimeInterval
    ) {
        self.observationID = observationID
        self.source = source
        self.capturedAt = capturedAt
        self.context = context
        self.text = text
        self.audioDuration = max(audioDuration, 0)
    }
}

struct BatchedAudioTranscript: Sendable {
    /// Every observation consumed by the batch, including cross-channel duplicates.
    var observationIDs: [UUID]

    /// Observations whose transcript contributes to `text`.
    var contributingObservationIDs: [UUID]

    /// Observations intentionally omitted because the other meeting channel carried
    /// a very similar transcript within the duplicate window.
    var deduplicatedObservationIDs: [UUID]

    var sources: [ObservationSource]
    var context: ActiveContext
    var startedAt: Date
    var capturedAt: Date
    var text: String
    var audioDuration: TimeInterval
}

enum AudioTranscriptSubmissionDisposition: Equatable, Sendable {
    case accepted
    case deduplicated(replacedCanonical: Bool)
    case cancelled
    case ignoredEmpty
    case ignoredUnsupportedSource
}

struct AudioTranscriptBatcherScheduler: Sendable {
    var now: @Sendable () async -> Date
    var sleepUntil: @Sendable (Date) async throws -> Void

    static let live = AudioTranscriptBatcherScheduler(
        now: { Date() },
        sleepUntil: { deadline in
            let delay = max(deadline.timeIntervalSinceNow, 0)
            try await Task.sleep(for: .seconds(delay))
        }
    )
}

/// Coalesces already-transcribed audio segments so one semantic interpretation can
/// cover a short continuous conversation. It never performs transcription or any
/// network operation itself.
actor AudioTranscriptBatcher {
    typealias Handler = @Sendable (BatchedAudioTranscript) async -> Void

    struct Tuning: Equatable, Sendable {
        var quietInterval: TimeInterval = 15
        var hardFlushInterval: TimeInterval = 60
        var crossChannelDuplicateWindow: TimeInterval = 5
        var crossChannelSimilarityThreshold: Double = 0.86
        var maximumTextCharacters: Int = 12_000
    }

    private struct ContextKey: Hashable, Sendable {
        var application: String
        var windowTitle: String
        var host: String
        var isMeeting: Bool
    }

    private struct TranscriptEntry: Sendable {
        var canonical: AudioTranscriptInput
        var allObservationIDs: [UUID]
        var allSources: [ObservationSource]
        var deduplicatedObservationIDs: [UUID]
    }

    private struct PendingBatch: Sendable {
        var key: ContextKey
        var context: ActiveContext
        var firstArrivalAt: Date
        var latestArrivalAt: Date
        var entries: [TranscriptEntry]
        var generation: UUID
    }

    private struct EmissionTask: Sendable {
        var task: Task<Void, Never>
        var observationIDs: [UUID]
    }

    private let tuning: Tuning
    private let scheduler: AudioTranscriptBatcherScheduler
    private var handler: Handler?
    private var pendingBatch: PendingBatch?
    private var scheduledFlushTask: Task<Void, Never>?
    private var emissionTasks: [UUID: EmissionTask] = [:]
    private var cancellationGeneration = 0

    init(
        tuning: Tuning = Tuning(),
        scheduler: AudioTranscriptBatcherScheduler = .live
    ) {
        self.tuning = tuning
        self.scheduler = scheduler
    }

    func start(handler: @escaping Handler) {
        self.handler = handler
    }

    @discardableResult
    func submit(_ input: AudioTranscriptInput) async -> AudioTranscriptSubmissionDisposition {
        guard Self.isSupportedAudioSource(input.source) else { return .ignoredUnsupportedSource }
        let cleanedText = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedText.isEmpty else { return .ignoredEmpty }

        var input = input
        input.text = cleanedText
        let submissionGeneration = cancellationGeneration
        let now = await scheduler.now()
        guard !Task.isCancelled,
              cancellationGeneration == submissionGeneration else { return .cancelled }
        let key = Self.contextKey(for: input.context)

        if let current = pendingBatch,
           current.key != key || now.timeIntervalSince(current.firstArrivalAt) >= tuning.hardFlushInterval {
            await emitPendingBatch()
            guard !Task.isCancelled,
                  cancellationGeneration == submissionGeneration else { return .cancelled }
        }

        if pendingBatch == nil {
            pendingBatch = PendingBatch(
                key: key,
                context: input.context,
                firstArrivalAt: now,
                latestArrivalAt: now,
                entries: [],
                generation: UUID()
            )
        }

        if pendingBatch?.key != key {
            // A handler may have re-entered the actor and opened another context
            // while the previous batch was being emitted. Preserve ordering by
            // flushing that context before accepting this input.
            await emitPendingBatch()
            guard !Task.isCancelled,
                  cancellationGeneration == submissionGeneration else { return .cancelled }
            pendingBatch = PendingBatch(
                key: key,
                context: input.context,
                firstArrivalAt: now,
                latestArrivalAt: now,
                entries: [],
                generation: UUID()
            )
        }

        pendingBatch?.context = input.context
        pendingBatch?.latestArrivalAt = now
        let disposition = incorporate(input)
        scheduleFlush()
        return disposition
    }

    /// Drops all buffered transcript content and returns the durable raw
    /// observation IDs that the owner must consume. This keeps a pause/private
    /// boundary from merely delaying the same semantic batch until its lease
    /// expires and is reclaimed.
    @discardableResult
    func cancel() -> [UUID] {
        let pendingObservationIDs = pendingBatch?.entries
            .flatMap(\.allObservationIDs)
            .uniqued() ?? []
        let inFlightObservationIDs = emissionTasks.values
            .flatMap(\.observationIDs)
            .uniqued()
        cancellationGeneration += 1
        scheduledFlushTask?.cancel()
        scheduledFlushTask = nil
        pendingBatch = nil
        emissionTasks.values.forEach { $0.task.cancel() }
        return (pendingObservationIDs + inFlightObservationIDs).uniqued()
    }

    @discardableResult
    func cancelAndDrain() async -> [UUID] {
        let observationIDs = cancel()
        while !emissionTasks.isEmpty {
            let tasks = emissionTasks
            for (identifier, emission) in tasks {
                await emission.task.value
                emissionTasks.removeValue(forKey: identifier)
            }
        }
        return observationIDs
    }

    func drainEmissions() async {
        let tasks = emissionTasks.values.map(\.task)
        for task in tasks { await task.value }
    }

    func flush() async {
        await emitPendingBatch()
    }

    private func incorporate(_ input: AudioTranscriptInput) -> AudioTranscriptSubmissionDisposition {
        guard var batch = pendingBatch else { return .accepted }

        if input.context.isMeeting,
           Self.isMeetingChannel(input.source),
           let duplicateIndex = batch.entries.firstIndex(where: { entry in
               Self.areOppositeMeetingChannels(entry.canonical.source, input.source) &&
                   abs(input.capturedAt.timeIntervalSince(entry.canonical.capturedAt)) <= tuning.crossChannelDuplicateWindow &&
                   Self.transcriptSimilarity(entry.canonical.text, input.text) >= tuning.crossChannelSimilarityThreshold
           }) {
            var entry = batch.entries[duplicateIndex]
            entry.allObservationIDs.append(input.observationID)
            entry.allSources.append(input.source)
            let replaceCanonical = Self.shouldPrefer(input, over: entry.canonical)
            if replaceCanonical {
                entry.deduplicatedObservationIDs.append(entry.canonical.observationID)
                entry.canonical = input
            } else {
                entry.deduplicatedObservationIDs.append(input.observationID)
            }
            batch.entries[duplicateIndex] = entry
            pendingBatch = batch
            return .deduplicated(replacedCanonical: replaceCanonical)
        }

        batch.entries.append(TranscriptEntry(
            canonical: input,
            allObservationIDs: [input.observationID],
            allSources: [input.source],
            deduplicatedObservationIDs: []
        ))
        pendingBatch = batch
        return .accepted
    }

    private func scheduleFlush() {
        scheduledFlushTask?.cancel()
        guard let batch = pendingBatch else {
            scheduledFlushTask = nil
            return
        }
        let quietDeadline = batch.latestArrivalAt.addingTimeInterval(tuning.quietInterval)
        let hardDeadline = batch.firstArrivalAt.addingTimeInterval(tuning.hardFlushInterval)
        let deadline = min(quietDeadline, hardDeadline)
        let generation = batch.generation
        let cancellationGeneration = cancellationGeneration
        let scheduler = scheduler
        scheduledFlushTask = Task { [weak self] in
            do {
                try await scheduler.sleepUntil(deadline)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.flushIfCurrent(
                generation: generation,
                cancellationGeneration: cancellationGeneration
            )
        }
    }

    private func flushIfCurrent(generation: UUID, cancellationGeneration: Int) async {
        guard self.cancellationGeneration == cancellationGeneration,
              pendingBatch?.generation == generation else { return }
        await emitPendingBatch()
    }

    private func emitPendingBatch() async {
        guard let batch = pendingBatch else { return }
        pendingBatch = nil
        scheduledFlushTask?.cancel()
        scheduledFlushTask = nil

        let entries = batch.entries.sorted { lhs, rhs in
            if lhs.canonical.capturedAt == rhs.canonical.capturedAt {
                return lhs.canonical.observationID.uuidString < rhs.canonical.observationID.uuidString
            }
            return lhs.canonical.capturedAt < rhs.canonical.capturedAt
        }
        guard !entries.isEmpty else { return }

        let observationIDs = entries.flatMap(\.allObservationIDs).uniqued()
        let contributingIDs = entries.map(\.canonical.observationID).uniqued()
        let deduplicatedIDs = entries.flatMap(\.deduplicatedObservationIDs).uniqued()
        let sources = entries.flatMap(\.allSources).uniqued()
        let texts = entries.map { $0.canonical.text }
        let startedAt = entries.map { $0.canonical.capturedAt }.min() ?? Date()
        let capturedAt = entries.map { $0.canonical.capturedAt }.max() ?? startedAt
        let duration = entries.reduce(0) { $0 + $1.canonical.audioDuration }
        let output = BatchedAudioTranscript(
            observationIDs: observationIDs,
            contributingObservationIDs: contributingIDs,
            deduplicatedObservationIDs: deduplicatedIDs,
            sources: sources,
            context: batch.context,
            startedAt: startedAt,
            capturedAt: capturedAt,
            text: Self.joinedText(texts, limit: tuning.maximumTextCharacters),
            audioDuration: duration
        )
        guard let handler else { return }
        let identifier = UUID()
        let task = Task { await handler(output) }
        emissionTasks[identifier] = EmissionTask(
            task: task,
            observationIDs: output.observationIDs
        )
        await task.value
        emissionTasks.removeValue(forKey: identifier)
    }

    nonisolated static func transcriptSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let lhsTokens = transcriptTokens(lhs)
        let rhsTokens = transcriptTokens(rhs)
        guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else { return 0 }
        if lhsTokens == rhsTokens { return 1 }

        var lhsCounts = lhsTokens.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        var intersection = 0
        for token in rhsTokens {
            guard let count = lhsCounts[token], count > 0 else { continue }
            intersection += 1
            lhsCounts[token] = count - 1
        }
        return (2 * Double(intersection)) / Double(lhsTokens.count + rhsTokens.count)
    }

    nonisolated static func joinedText(_ values: [String], limit: Int) -> String {
        guard limit > 0 else { return "" }
        var result = ""
        for value in values {
            let separator = result.isEmpty ? "" : "\n\n"
            let available = limit - result.count - separator.count
            guard available > 0 else { break }
            result += separator + String(value.prefix(available))
        }
        return result
    }

    private nonisolated static func transcriptTokens(_ value: String) -> [String] {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    private nonisolated static func contextKey(for context: ActiveContext) -> ContextKey {
        ContextKey(
            application: (context.bundleIdentifier ?? context.applicationName ?? "").lowercased(),
            windowTitle: normalizedContextValue(context.windowTitle ?? ""),
            host: context.url?.host()?.lowercased() ?? "",
            isMeeting: context.isMeeting
        )
    }

    private nonisolated static func normalizedContextValue(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }

    private nonisolated static func isSupportedAudioSource(_ source: ObservationSource) -> Bool {
        switch source {
        case .ambientAudio, .meetingMicrophone, .meetingSystemAudio: true
        case .screen, .manualNote: false
        }
    }

    private nonisolated static func isMeetingChannel(_ source: ObservationSource) -> Bool {
        source == .meetingMicrophone || source == .meetingSystemAudio
    }

    private nonisolated static func areOppositeMeetingChannels(
        _ lhs: ObservationSource,
        _ rhs: ObservationSource
    ) -> Bool {
        (lhs == .meetingMicrophone && rhs == .meetingSystemAudio) ||
            (lhs == .meetingSystemAudio && rhs == .meetingMicrophone)
    }

    private nonisolated static func shouldPrefer(
        _ candidate: AudioTranscriptInput,
        over current: AudioTranscriptInput
    ) -> Bool {
        if candidate.source != current.source {
            // System audio is normally the cleaner copy when the remote speaker is
            // also picked up by the microphone channel.
            return candidate.source == .meetingSystemAudio
        }
        return candidate.text.count > current.text.count
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
