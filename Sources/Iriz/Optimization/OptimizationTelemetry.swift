import Foundation

/// Operational optimization signals only. The schema deliberately has no free-form
/// strings, fingerprints, prompts, OCR, transcripts, titles, URLs, or identifiers
/// that can be correlated with user content.
enum OptimizationTelemetryMetric: String, Codable, CaseIterable, Sendable {
    case captureAttempted
    case captureDelivered
    case captureStableSkipped
    case captureContextUnavailable
    case captureUnavailable
    case captureFailed
    case captureQueueDropped

    case batchFrameAccepted
    case batchFrameDropped
    case batchEmitted
    case batchSuppressedDuplicate
    case batchCancelled
    case batchFlushed

    case appleGateSuppressedCloud
    case appleGateUsedCloud
    case appleGateShadowCompared

    case refinementAvoided
    case refinementCoalesced
    case refinementDiscardedStale
    case refinementAbandonedFlex
    case refinementQueueWait
    case refinementCompleted
    case eventVisible
}

enum OptimizationTelemetryReason: String, Codable, CaseIterable, Sendable {
    case unchangedFrame
    case unavailableContext
    case permissionUnavailable
    case captureError
    case queueCapacity
    case contextChanged
    case quietInterval
    case hardDeadline
    case highRiskSignal
    case duplicateOCR
    case duplicateTranscript
    case pauseOrPrivateContext

    case gateDisabled
    case shadowMode
    case meeting
    case manualNote
    case retry
    case visualContextRequired
    case insufficientText
    case appleModelUnavailable
    case unqualifiedAppleModel
    case clearlyEmpty
    case uncertain
    case meaningful
    case generationFailed

    case commitmentOnly
    case coalesced
    case staleRevision
    case flexUnavailable
    case criticalEvent
    case normalEvent
}

enum OptimizationTelemetrySource: String, Codable, CaseIterable, Sendable {
    case screen
    case microphone
    case systemAudio
    case manual
    case unknown

    init(_ source: ObservationSource) {
        self = switch source {
        case .screen: .screen
        case .ambientAudio, .meetingMicrophone: .microphone
        case .meetingSystemAudio: .systemAudio
        case .manualNote: .manual
        }
    }
}

struct OptimizationTelemetryRecord: Codable, Equatable, Sendable {
    let id: UUID
    let occurredAt: Date
    let metric: OptimizationTelemetryMetric
    let reason: OptimizationTelemetryReason?
    let source: OptimizationTelemetrySource?
    let occurrenceCount: Int
    let latencyMilliseconds: Int?
    let queueDepth: Int?
    let fromCache: Bool?
    let isMeeting: Bool?

    init(
        id: UUID = UUID(),
        occurredAt: Date = Date(),
        metric: OptimizationTelemetryMetric,
        reason: OptimizationTelemetryReason? = nil,
        source: OptimizationTelemetrySource? = nil,
        occurrenceCount: Int = 1,
        latencyMilliseconds: Int? = nil,
        queueDepth: Int? = nil,
        fromCache: Bool? = nil,
        isMeeting: Bool? = nil
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.metric = metric
        self.reason = reason
        self.source = source
        self.occurrenceCount = max(1, occurrenceCount)
        self.latencyMilliseconds = latencyMilliseconds.map { max(0, $0) }
        self.queueDepth = queueDepth.map { max(0, $0) }
        self.fromCache = fromCache
        self.isMeeting = isMeeting
    }
}

struct OptimizationTelemetryDailyAggregate: Codable, Equatable, Sendable {
    let day: String
    let metric: OptimizationTelemetryMetric
    let recordCount: Int
    let occurrenceCount: Int
    let totalLatencyMilliseconds: Int
    let maximumQueueDepth: Int
}

protocol OptimizationTelemetryRecording: Sendable {
    func record(_ record: OptimizationTelemetryRecord) async
}

struct NoOpOptimizationTelemetryRecorder: OptimizationTelemetryRecording {
    func record(_ record: OptimizationTelemetryRecord) async {}
}

actor InMemoryOptimizationTelemetryRecorder: OptimizationTelemetryRecording {
    private var values: [OptimizationTelemetryRecord] = []

    func record(_ record: OptimizationTelemetryRecord) {
        values.append(record)
    }

    func records() -> [OptimizationTelemetryRecord] {
        values
    }
}

actor PersistentOptimizationTelemetryRecorder: OptimizationTelemetryRecording {
    typealias SaveHandler = @Sendable ([OptimizationTelemetryRecord]) async throws -> Void

    private var saveHandler: SaveHandler?
    private var buffered: [OptimizationTelemetryRecord] = []
    private var scheduledFlush: Task<Void, Never>?
    private var isFlushing = false
    private var flushWaiters: [CheckedContinuation<Void, Never>] = []
    private let maximumBatchSize: Int
    private let flushInterval: TimeInterval

    init(maximumBatchSize: Int = 40, flushInterval: TimeInterval = 60) {
        self.maximumBatchSize = max(1, maximumBatchSize)
        self.flushInterval = max(0.1, flushInterval)
    }

    func attach(repository: any LogRepository) async {
        saveHandler = { records in
            try await repository.saveOptimizationTelemetryRecords(records)
        }
        await flush()
    }

    func attach(saveHandler: @escaping SaveHandler) async {
        self.saveHandler = saveHandler
        await flush()
    }

    func record(_ record: OptimizationTelemetryRecord) async {
        buffered.append(record)
        if buffered.count >= maximumBatchSize {
            await flush()
        } else {
            scheduleFlushIfNeeded()
        }
    }

    func flush() async {
        try? await persistBuffered(reportFailure: false)
    }

    /// Used by orderly termination so a failed tail write is observable and
    /// the buffered records remain available for a later retry.
    func flushDurably(maxAttempts: Int = 3) async throws {
        let attempts = max(1, maxAttempts)
        for attempt in 1...attempts {
            do {
                try await persistBuffered(reportFailure: true)
                return
            } catch {
                guard attempt < attempts else { throw error }
                try? await Task.sleep(for: .milliseconds(100 * attempt))
            }
        }
    }

    private func persistBuffered(reportFailure: Bool) async throws {
        scheduledFlush?.cancel()
        scheduledFlush = nil
        if isFlushing {
            await withCheckedContinuation { continuation in
                flushWaiters.append(continuation)
            }
            if !buffered.isEmpty {
                try await persistBuffered(reportFailure: reportFailure)
            }
            return
        }
        guard !buffered.isEmpty else { return }
        guard let saveHandler else {
            if reportFailure { throw DurableRecorderError.persistenceUnavailable }
            return
        }
        isFlushing = true
        defer {
            isFlushing = false
            let waiters = flushWaiters
            flushWaiters.removeAll(keepingCapacity: true)
            waiters.forEach { $0.resume() }
        }
        while !buffered.isEmpty {
            let pending = buffered
            let persistedIDs = Set(pending.map(\.id))
            do {
                try await saveHandler(pending)
                buffered.removeAll { persistedIDs.contains($0.id) }
            } catch {
                scheduleFlushIfNeeded()
                if reportFailure { throw error }
                return
            }
        }
    }

    func bufferedCount() -> Int {
        buffered.count
    }

    private func scheduleFlushIfNeeded() {
        guard scheduledFlush == nil else { return }
        let delay = flushInterval
        scheduledFlush = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }
}

typealias OptimizationTelemetryHandler = @Sendable (OptimizationTelemetryRecord) async -> Void
