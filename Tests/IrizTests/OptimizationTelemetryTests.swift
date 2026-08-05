import CoreGraphics
import Foundation
import Testing
@testable import Iriz

@Suite("Content-free optimization telemetry")
struct OptimizationTelemetryTests {
    private let keyData = Data(repeating: 0x39, count: 32)

    @Test("The detailed schema contains no free-form content field")
    func contentFreeSchema() throws {
        let record = OptimizationTelemetryRecord(
            occurredAt: Date(timeIntervalSince1970: 2_000_000_000),
            metric: .batchSuppressedDuplicate,
            reason: .duplicateOCR,
            source: .screen,
            occurrenceCount: 2,
            latencyMilliseconds: 1_500,
            queueDepth: 3,
            fromCache: true,
            isMeeting: false
        )
        let object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(record)
        ) as? [String: Any])

        #expect(Set(object.keys) == [
            "id", "occurredAt", "metric", "reason", "source", "occurrenceCount",
            "latencyMilliseconds", "queueDepth", "fromCache", "isMeeting"
        ])
        #expect(object["text"] == nil)
        #expect(object["contentFingerprint"] == nil)
        #expect(object["url"] == nil)
        #expect(object["prompt"] == nil)
    }

    @Test("Detail is kept for 30 days and daily aggregates for 90 days")
    func encryptedPersistenceRetentionAndAggregation() async throws {
        let directory = temporaryDirectory(named: "Persistence")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try EncryptedSQLiteStore(directory: directory, keyData: keyData)
        let now = Date(timeIntervalSince1970: 2_000_300_000)
        let recent = record(
            at: now.addingTimeInterval(-10 * 86_400),
            metric: .captureQueueDropped,
            count: 2,
            latency: 30,
            depth: 3
        )
        let detailExpired = record(
            at: now.addingTimeInterval(-31 * 86_400),
            metric: .batchEmitted,
            count: 1,
            latency: 10_000,
            depth: 1
        )
        let aggregateExpired = record(
            at: now.addingTimeInterval(-91 * 86_400),
            metric: .appleGateUsedCloud,
            count: 1,
            latency: 600,
            depth: nil
        )

        try await store.saveOptimizationTelemetryRecords([
            recent, recent, detailExpired, aggregateExpired
        ])
        #expect(try await store.optimizationTelemetryRecords(since: .distantPast, limit: 20).count == 3)
        let beforePurge = try await store.optimizationTelemetryDailyAggregates(since: .distantPast)
        #expect(beforePurge.count == 3)
        #expect(beforePurge.reduce(0, { $0 + $1.recordCount }) == 3)

        try await store.purgeExpired(now: now, retention: .forever)
        let detail = try await store.optimizationTelemetryRecords(since: .distantPast, limit: 20)
        let aggregates = try await store.optimizationTelemetryDailyAggregates(since: .distantPast)
        #expect(detail == [recent])
        #expect(aggregates.count == 2)
        #expect(aggregates.reduce(0, { $0 + $1.occurrenceCount }) == 3)

        let recentAggregate = try #require(aggregates.first(where: {
            $0.metric == .captureQueueDropped
        }))
        #expect(recentAggregate.recordCount == 1)
        #expect(recentAggregate.occurrenceCount == 2)
        #expect(recentAggregate.totalLatencyMilliseconds == 30)
        #expect(recentAggregate.maximumQueueDepth == 3)

        let encryptedBytes = try Data(contentsOf: directory.appendingPathComponent("Iriz.sqlite.iriz"))
        #expect(!String(decoding: encryptedBytes, as: UTF8.self).contains(recent.metric.rawValue))
    }

    @Test("The persistent recorder buffers before attachment and flushes in bounded batches")
    func persistentRecorderBuffering() async throws {
        let directory = temporaryDirectory(named: "Recorder")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try EncryptedSQLiteStore(directory: directory, keyData: keyData)
        let recorder = PersistentOptimizationTelemetryRecorder(maximumBatchSize: 2, flushInterval: 600)
        let first = record(at: Date(), metric: .captureDelivered)
        let second = record(at: Date().addingTimeInterval(1), metric: .batchEmitted)

        await recorder.record(first)
        #expect(await recorder.bufferedCount() == 1)
        await recorder.attach(repository: store)
        #expect(await recorder.bufferedCount() == 0)
        await recorder.record(second)
        await recorder.flush()

        let stored = try await store.optimizationTelemetryRecords(since: .distantPast, limit: 10)
        #expect(Set(stored.map(\.id)) == [first.id, second.id])
    }

    @Test("Concurrent telemetry flushes never remove a record outside their saved snapshot")
    func concurrentFlushPreservesInterleavedRecord() async {
        let sink = SuspendedOptimizationTelemetrySink()
        let recorder = PersistentOptimizationTelemetryRecorder(maximumBatchSize: 100, flushInterval: 600)
        await recorder.attach(saveHandler: { records in
            await sink.save(records)
        })
        let first = record(at: Date(), metric: .captureDelivered)
        let second = record(at: Date().addingTimeInterval(1), metric: .eventVisible)
        await recorder.record(first)

        let firstFlush = Task { await recorder.flush() }
        await sink.waitUntilFirstSaveStarts()
        await recorder.record(second)
        let overlappingFlush = Task { await recorder.flush() }
        await sink.releaseFirstSave()
        await firstFlush.value
        await overlappingFlush.value

        #expect(await recorder.bufferedCount() == 0)
        #expect(await sink.savedIDs() == Set([first.id, second.id]))
    }

    @Test("A durable telemetry flush retries transient failures and retains a persistent tail")
    func durableFlushFailureSemantics() async {
        let transientSink = RetryingOptimizationTelemetrySink(failuresBeforeSuccess: 2)
        let transientRecorder = PersistentOptimizationTelemetryRecorder(
            maximumBatchSize: 100,
            flushInterval: 600
        )
        await transientRecorder.attach(saveHandler: { records in
            try await transientSink.save(records)
        })
        let transientRecord = record(at: Date(), metric: .captureDelivered)
        await transientRecorder.record(transientRecord)
        try? await transientRecorder.flushDurably(maxAttempts: 3)
        #expect(await transientSink.attemptCount() == 3)
        #expect(await transientSink.savedIDs() == [transientRecord.id])
        #expect(await transientRecorder.bufferedCount() == 0)

        let persistentSink = RetryingOptimizationTelemetrySink(failuresBeforeSuccess: .max)
        let persistentRecorder = PersistentOptimizationTelemetryRecorder(
            maximumBatchSize: 100,
            flushInterval: 600
        )
        await persistentRecorder.attach(saveHandler: { records in
            try await persistentSink.save(records)
        })
        await persistentRecorder.record(record(at: Date(), metric: .batchEmitted))
        await #expect(throws: RecorderFixtureError.self) {
            try await persistentRecorder.flushDurably(maxAttempts: 3)
        }
        #expect(await persistentSink.attemptCount() == 3)
        #expect(await persistentRecorder.bufferedCount() == 1)
    }

    @Test("Bounded dispatch reports capacity drops without inspecting an element")
    func dispatcherDropSignal() async {
        let probe = BlockingTelemetryDispatchProbe()
        let dispatcher = BoundedAsyncDispatcher<Int>(capacity: 1) { value in
            await probe.receive(value)
        }

        _ = await dispatcher.submit(0)
        await probe.waitUntilBlocked()
        let firstWaiting = await dispatcher.submit(1)
        let replacement = await dispatcher.submit(2)
        #expect(firstWaiting.droppedCount == 0)
        #expect(replacement.droppedCount == 1)
        #expect(replacement.pendingDepth == 1)
        await probe.release()
    }

    @Test("Apple gate records only its typed routing outcome")
    @available(macOS 26.0, *)
    func appleGateTelemetry() async throws {
        let provider = TelemetryGateProvider()
        let environment = await provider.environment(localeIdentifier: "fr-FR")
        let registry = AppleQualificationRegistry(profiles: [
            AppleQualificationProfile(
                fingerprint: environment.fingerprint,
                gateEnabled: true,
                qualifiedAt: Date()
            )
        ])
        let recorder = InMemoryOptimizationTelemetryRecorder()
        let gate = AppleFoundationModelGate(
            provider: provider,
            registry: registry,
            telemetryHandler: { record in await recorder.record(record) }
        )

        let decision = await gate.route(LocalGateInput(
            source: .screen,
            applicationName: "Browser",
            windowTitle: "New tab",
            text: "Browsing a generic product overview and opening navigation menus.",
            languageTag: "fr-FR"
        ), mode: .adaptive)

        #expect(decision.route == .suppressCloud)
        let records = await recorder.records()
        #expect(records.count == 1)
        #expect(records.first?.metric == .appleGateSuppressedCloud)
        #expect(records.first?.reason == .clearlyEmpty)
        #expect(records.first?.source == .screen)
    }

    private func record(
        at date: Date,
        metric: OptimizationTelemetryMetric,
        count: Int = 1,
        latency: Int? = nil,
        depth: Int? = nil
    ) -> OptimizationTelemetryRecord {
        OptimizationTelemetryRecord(
            occurredAt: date,
            metric: metric,
            occurrenceCount: count,
            latencyMilliseconds: latency,
            queueDepth: depth
        )
    }

    private func temporaryDirectory(named suffix: String) -> URL {
        URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("IrizTelemetry-\(suffix)-\(UUID().uuidString)", isDirectory: true)
    }
}

private actor SuspendedOptimizationTelemetrySink {
    private var saved = Set<UUID>()
    private var firstSaveStarted = false
    private var firstSaveWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func save(_ records: [OptimizationTelemetryRecord]) async {
        if !firstSaveStarted {
            firstSaveStarted = true
            let waiters = firstSaveWaiters
            firstSaveWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        saved.formUnion(records.map(\.id))
    }

    func waitUntilFirstSaveStarts() async {
        guard !firstSaveStarted else { return }
        await withCheckedContinuation { continuation in
            firstSaveWaiters.append(continuation)
        }
    }

    func releaseFirstSave() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func savedIDs() -> Set<UUID> { saved }
}

private enum RecorderFixtureError: Error {
    case persistenceFailed
}

private actor RetryingOptimizationTelemetrySink {
    private let failuresBeforeSuccess: Int
    private var attempts = 0
    private var saved = Set<UUID>()

    init(failuresBeforeSuccess: Int) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    func save(_ records: [OptimizationTelemetryRecord]) throws {
        attempts += 1
        if attempts <= failuresBeforeSuccess {
            throw RecorderFixtureError.persistenceFailed
        }
        saved.formUnion(records.map(\.id))
    }

    func attemptCount() -> Int { attempts }
    func savedIDs() -> Set<UUID> { saved }
}

private actor BlockingTelemetryDispatchProbe {
    private var blocked = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func receive(_ value: Int) async {
        guard value == 0 else { return }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
            blocked = true
            blockedWaiters.forEach { $0.resume() }
            blockedWaiters.removeAll()
        }
    }

    func waitUntilBlocked() async {
        if blocked { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
        blocked = false
    }
}

@available(macOS 26.0, *)
private actor TelemetryGateProvider: LocalGateModelProviding {
    func environment(localeIdentifier: String) -> LocalGateModelEnvironment {
        LocalGateModelEnvironment(
            availability: .available,
            fingerprint: AppleModelFingerprint(
                operatingSystemMajor: 26,
                operatingSystemMinor: 5,
                localeIdentifier: localeIdentifier,
                promptVersion: SystemFoundationModelGateProvider.promptVersion,
                schemaVersion: SystemFoundationModelGateProvider.schemaVersion
            )
        )
    }

    func prewarm() {}

    func classify(prompt: String) async throws -> LocalGateVerdict {
        .clearlyEmpty
    }
}
