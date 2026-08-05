import Foundation

struct OpenAIUsageDailyAggregate: Codable, Equatable, Sendable {
    var day: String
    var priceVersion: String
    var requestCount: Int
    var inputTokens: Int
    var cachedInputTokens: Int
    var cacheWriteTokens: Int
    var outputTokens: Int
    var reasoningTokens: Int
    var totalTokens: Int
    var estimatedCostUSD: Double
}

enum OpenAICostEstimator {
    enum Basis: String, Codable, Sendable {
        case tokenTable
        case estimatedAudioDuration
    }

    struct Estimate: Equatable, Sendable {
        var amountUSD: Double
        var basis: Basis
    }

    struct Price: Sendable {
        var inputPerMillion: Double
        var cachedInputPerMillion: Double
        var outputPerMillion: Double
    }

    // Versioned against the public GPT-5.6 prices on 2026-08-05. This is an
    // estimate for developer diagnostics, never presented as an invoice.
    static let priceVersion = "2026-08-05"
    /// Public per-minute rates. They remain estimates in Iriz because the API
    /// does not return the exact billed USD amount for an individual request.
    static let gptTranscribePerMinuteUSD = 0.0045
    static let gpt4oTranscribePerMinuteUSD = 0.006

    static func estimatedCostUSD(for record: OpenAIUsageRecord) -> Double {
        estimate(for: record)?.amountUSD ?? 0
    }

    static func estimate(for record: OpenAIUsageRecord) -> Estimate? {
        let model = record.actualModel ?? record.requestedModel
        let normalizedModel = model.lowercased()
        if isGPTTranscribeModel(normalizedModel) {
            guard let duration = record.audioDurationSeconds, duration > 0 else { return nil }
            return Estimate(
                amountUSD: duration / 60 * gptTranscribePerMinuteUSD,
                basis: .estimatedAudioDuration
            )
        }
        if isGPT4oTranscriptionModel(normalizedModel) {
            let input = max(0, record.inputTokens ?? 0)
            let output = max(0, record.outputTokens ?? 0)
            if input > 0 || output > 0 {
                return Estimate(
                    amountUSD: (
                        Double(input) * 2.50
                            + Double(output) * 10.00
                    ) / 1_000_000,
                    basis: .tokenTable
                )
            }
            guard let duration = record.audioDurationSeconds, duration > 0 else { return nil }
            return Estimate(
                amountUSD: duration / 60 * gpt4oTranscribePerMinuteUSD,
                basis: .estimatedAudioDuration
            )
        }

        guard let price = price(for: model) else { return nil }
        let multiplier = (record.actualServiceTier ?? record.requestedServiceTier) == OpenAIServiceTier.flex.rawValue
            ? 0.5
            : 1.0
        let input = max(0, record.inputTokens ?? 0)
        let cached = min(input, max(0, record.cachedInputTokens ?? 0))
        let writes = max(0, record.cacheWriteTokens ?? 0)
        let uncached = max(0, input - cached - writes)
        let output = max(0, record.outputTokens ?? 0)
        return Estimate(
            amountUSD: multiplier * (
                Double(uncached) * price.inputPerMillion
                    + Double(cached) * price.cachedInputPerMillion
                    + Double(writes) * price.inputPerMillion * 1.25
                    + Double(output) * price.outputPerMillion
            ) / 1_000_000,
            basis: .tokenTable
        )
    }

    private static func isGPTTranscribeModel(_ model: String) -> Bool {
        model == "gpt-transcribe" || model.hasPrefix("gpt-transcribe-")
    }

    private static func isGPT4oTranscriptionModel(_ model: String) -> Bool {
        model == "gpt-4o-transcribe" || model.hasPrefix("gpt-4o-transcribe-")
    }

    private static func price(for model: String) -> Price? {
        if model.contains("gpt-5.6-luna") {
            return Price(inputPerMillion: 1, cachedInputPerMillion: 0.10, outputPerMillion: 6)
        }
        if model.contains("gpt-5.6-terra") {
            return Price(inputPerMillion: 2.50, cachedInputPerMillion: 0.25, outputPerMillion: 15)
        }
        return nil
    }
}

actor PersistentOpenAIUsageRecorder: OpenAIUsageRecording {
    typealias SaveHandler = @Sendable ([OpenAIUsageRecord]) async throws -> Void

    private var saveHandler: SaveHandler?
    private var buffered: [OpenAIUsageRecord] = []
    private var scheduledFlush: Task<Void, Never>?
    private var isFlushing = false
    private var flushWaiters: [CheckedContinuation<Void, Never>] = []
    private let maximumBatchSize: Int
    private let flushInterval: TimeInterval

    init(maximumBatchSize: Int = 20, flushInterval: TimeInterval = 60) {
        self.maximumBatchSize = maximumBatchSize
        self.flushInterval = flushInterval
    }

    func attach(repository: any LogRepository) async {
        saveHandler = { records in
            try await repository.saveOpenAIUsageRecords(records)
        }
        await flush()
    }

    func attach(saveHandler: @escaping SaveHandler) async {
        self.saveHandler = saveHandler
        await flush()
    }

    func record(_ record: OpenAIUsageRecord) async {
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

    /// Used by orderly termination. Unlike the periodic best-effort flush, a
    /// persistence failure is surfaced while retaining every unsaved record.
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
            let values = buffered
            let persistedIDs = Set(values.map(\.id))
            do {
                try await saveHandler(values)
                // Actor reentrancy allows new records to arrive during the save.
                // Remove only the exact snapshot that succeeded.
                buffered.removeAll { persistedIDs.contains($0.id) }
            } catch {
                scheduleFlushIfNeeded()
                if reportFailure { throw error }
                return
            }
        }
    }

    func bufferedCount() -> Int { buffered.count }

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

enum DurableRecorderError: LocalizedError, Equatable, Sendable {
    case persistenceUnavailable

    var errorDescription: String? {
        "Encrypted telemetry storage is not available."
    }
}
