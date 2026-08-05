import Foundation
import Testing
@testable import Iriz

@Suite("Audio transcript batching")
struct AudioTranscriptBatcherTests {
    @Test("Production defaults use 15 second quiet and 60 second hard flush windows")
    func productionDefaults() {
        let tuning = AudioTranscriptBatcher.Tuning()

        #expect(tuning.quietInterval == 15)
        #expect(tuning.hardFlushInterval == 60)
        #expect(tuning.crossChannelDuplicateWindow == 5)
    }

    @Test("Same-context transcripts flush after 15 seconds of calm")
    func quietFlush() async {
        let start = Date(timeIntervalSince1970: 1_000)
        let scheduler = ManualAudioBatcherScheduler(now: start)
        let probe = AudioBatchProbe()
        let batcher = AudioTranscriptBatcher(scheduler: await scheduler.interface())
        await batcher.start { batch in await probe.receive(batch) }

        let firstID = UUID()
        let secondID = UUID()
        let context = Self.context(title: "Customer call", isMeeting: false)
        await batcher.submit(Self.input(
            id: firstID,
            text: "We reviewed the first topic.",
            at: start,
            context: context
        ))
        await scheduler.advance(by: 10)
        await batcher.submit(Self.input(
            id: secondID,
            text: "Then we reviewed the second topic.",
            at: start.addingTimeInterval(10),
            context: context
        ))

        await scheduler.advance(by: 14)
        #expect(await probe.count == 0)
        await scheduler.advance(by: 1)
        #expect(await eventually { await probe.count == 1 })

        let output = await probe.first
        #expect(output?.observationIDs == [firstID, secondID])
        #expect(output?.text == "We reviewed the first topic.\n\nThen we reviewed the second topic.")
    }

    @Test("Continuous transcripts are forced out at 60 seconds")
    func hardFlush() async {
        let start = Date(timeIntervalSince1970: 2_000)
        let scheduler = ManualAudioBatcherScheduler(now: start)
        let probe = AudioBatchProbe()
        let batcher = AudioTranscriptBatcher(scheduler: await scheduler.interface())
        await batcher.start { batch in await probe.receive(batch) }
        let context = Self.context(title: "Long discussion", isMeeting: false)

        await batcher.submit(Self.input(id: UUID(), text: "Segment zero", at: start, context: context))
        for (offset, text) in [(14.0, "Segment one"), (28.0, "Segment two"), (42.0, "Segment three"), (56.0, "Segment four")] {
            await scheduler.advance(to: start.addingTimeInterval(offset))
            await batcher.submit(Self.input(
                id: UUID(),
                text: text,
                at: start.addingTimeInterval(offset),
                context: context
            ))
        }

        await scheduler.advance(to: start.addingTimeInterval(59))
        #expect(await probe.count == 0)
        await scheduler.advance(to: start.addingTimeInterval(60))
        #expect(await eventually { await probe.count == 1 })
        #expect(await probe.first?.observationIDs.count == 5)
    }

    @Test("A context change flushes the previous transcript immediately")
    func contextChangeFlush() async {
        let start = Date(timeIntervalSince1970: 3_000)
        let scheduler = ManualAudioBatcherScheduler(now: start)
        let probe = AudioBatchProbe()
        let batcher = AudioTranscriptBatcher(scheduler: await scheduler.interface())
        await batcher.start { batch in await probe.receive(batch) }

        await batcher.submit(Self.input(
            id: UUID(),
            text: "First context",
            at: start,
            context: Self.context(title: "Call A", isMeeting: false)
        ))
        await batcher.submit(Self.input(
            id: UUID(),
            text: "Second context",
            at: start,
            context: Self.context(title: "Call B", isMeeting: false)
        ))

        #expect(await probe.count == 1)
        #expect(await probe.first?.text == "First context")
        await batcher.flush()
        #expect(await probe.count == 2)
    }

    @Test("Similar microphone and system meeting transcripts are interpreted once")
    func meetingCrossChannelDeduplication() async {
        let start = Date(timeIntervalSince1970: 4_000)
        let scheduler = ManualAudioBatcherScheduler(now: start)
        let probe = AudioBatchProbe()
        let batcher = AudioTranscriptBatcher(scheduler: await scheduler.interface())
        await batcher.start { batch in await probe.receive(batch) }
        let context = Self.context(title: "Weekly review", isMeeting: true)
        let microphoneID = UUID()
        let systemID = UUID()

        await batcher.submit(Self.input(
            id: microphoneID,
            source: .meetingMicrophone,
            text: "Speaker 1: We will send the revised proposal tomorrow morning.",
            at: start,
            context: context,
            duration: 4.2
        ))
        let disposition = await batcher.submit(Self.input(
            id: systemID,
            source: .meetingSystemAudio,
            text: "Speaker 1 — We will send the revised proposal tomorrow morning!",
            at: start.addingTimeInterval(3),
            context: context,
            duration: 3.8
        ))
        await batcher.flush()

        #expect(disposition == .deduplicated(replacedCanonical: true))
        let output = await probe.first
        #expect(output?.observationIDs == [microphoneID, systemID])
        #expect(output?.contributingObservationIDs == [systemID])
        #expect(output?.deduplicatedObservationIDs == [microphoneID])
        #expect(output?.sources == [.meetingMicrophone, .meetingSystemAudio])
        #expect(output?.text == "Speaker 1 — We will send the revised proposal tomorrow morning!")
        #expect(output?.audioDuration == 3.8)
    }

    @Test("Cross-channel transcripts outside five seconds remain distinct")
    func duplicateWindowBoundary() async {
        let start = Date(timeIntervalSince1970: 5_000)
        let scheduler = ManualAudioBatcherScheduler(now: start)
        let probe = AudioBatchProbe()
        let batcher = AudioTranscriptBatcher(scheduler: await scheduler.interface())
        await batcher.start { batch in await probe.receive(batch) }
        let context = Self.context(title: "Weekly review", isMeeting: true)

        await batcher.submit(Self.input(
            id: UUID(),
            source: .meetingMicrophone,
            text: "We approved the final design today.",
            at: start,
            context: context
        ))
        let disposition = await batcher.submit(Self.input(
            id: UUID(),
            source: .meetingSystemAudio,
            text: "We approved the final design today.",
            at: start.addingTimeInterval(5.01),
            context: context
        ))
        await batcher.flush()

        #expect(disposition == .accepted)
        #expect(await probe.first?.contributingObservationIDs.count == 2)
        #expect(await probe.first?.deduplicatedObservationIDs.isEmpty == true)
    }

    @Test("Cancellation drops buffered transcripts and scheduled work")
    func cancellation() async {
        let start = Date(timeIntervalSince1970: 6_000)
        let scheduler = ManualAudioBatcherScheduler(now: start)
        let probe = AudioBatchProbe()
        let batcher = AudioTranscriptBatcher(scheduler: await scheduler.interface())
        await batcher.start { batch in await probe.receive(batch) }
        let observationID = UUID()
        await batcher.submit(Self.input(
            id: observationID,
            text: "This transcript must be discarded.",
            at: start,
            context: Self.context(title: "Private", isMeeting: false)
        ))

        let discardedIDs = await batcher.cancel()
        #expect(discardedIDs == [observationID])
        await scheduler.advance(by: 120)
        _ = await eventually { await probe.count > 0 }
        #expect(await probe.count == 0)
        await batcher.flush()
        #expect(await probe.count == 0)
    }

    @Test("Cancellation returns observation IDs from an in-flight emission and drains its handler")
    func inFlightCancellation() async {
        let start = Date(timeIntervalSince1970: 6_500)
        let probe = CancellableAudioBatchProbe()
        let batcher = AudioTranscriptBatcher()
        await batcher.start { batch in await probe.receive(batch) }
        let observationID = UUID()
        await batcher.submit(Self.input(
            id: observationID,
            text: "This in-flight transcript crosses a privacy boundary.",
            at: start,
            context: Self.context(title: "Private", isMeeting: false)
        ))

        let flushTask = Task { await batcher.flush() }
        await probe.waitUntilStarted()
        let discardedIDs = await batcher.cancelAndDrain()
        await flushTask.value

        #expect(discardedIDs == [observationID])
        #expect(await probe.wasCancelled)
    }

    @Test("Cancellation rejects a transcript suspended before admission")
    func cancellationDuringSchedulerLookup() async {
        let start = Date(timeIntervalSince1970: 6_750)
        let scheduler = BlockingNowAudioBatcherScheduler(now: start)
        let probe = AudioBatchProbe()
        let batcher = AudioTranscriptBatcher(scheduler: await scheduler.interface())
        await batcher.start { batch in await probe.receive(batch) }

        let submission = Task {
            await batcher.submit(Self.input(
                id: UUID(),
                text: "This late transcript must not cross the boundary.",
                at: start,
                context: Self.context(title: "Private", isMeeting: false)
            ))
        }
        await scheduler.waitUntilNowBlocks()
        let discardedIDs = await batcher.cancelAndDrain()
        await scheduler.releaseNow()
        let disposition = await submission.value
        await batcher.flush()

        #expect(discardedIDs.isEmpty)
        #expect(disposition == .cancelled)
        #expect(await probe.count == 0)
    }

    private static func input(
        id: UUID,
        source: ObservationSource = .ambientAudio,
        text: String,
        at date: Date,
        context: ActiveContext,
        duration: TimeInterval = 1
    ) -> AudioTranscriptInput {
        AudioTranscriptInput(
            observationID: id,
            source: source,
            capturedAt: date,
            context: context,
            text: text,
            audioDuration: duration
        )
    }

    private static func context(title: String, isMeeting: Bool) -> ActiveContext {
        ActiveContext(
            applicationName: isMeeting ? "FaceTime" : "Voice Notes",
            bundleIdentifier: isMeeting ? "com.apple.FaceTime" : "com.example.voice",
            windowTitle: title,
            url: nil,
            isMeeting: isMeeting
        )
    }
}

private actor AudioBatchProbe {
    private(set) var batches: [BatchedAudioTranscript] = []

    var count: Int { batches.count }
    var first: BatchedAudioTranscript? { batches.first }

    func receive(_ batch: BatchedAudioTranscript) {
        batches.append(batch)
    }
}

private actor CancellableAudioBatchProbe {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var wasCancelled = false

    func receive(_ batch: BatchedAudioTranscript) async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        do {
            try await Task.sleep(for: .seconds(60))
        } catch {
            wasCancelled = true
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }
}

private actor ManualAudioBatcherScheduler {
    private struct Waiter {
        var deadline: Date
        var continuation: CheckedContinuation<Void, any Error>
    }

    private var currentDate: Date
    private var waiters: [UUID: Waiter] = [:]

    init(now: Date) {
        currentDate = now
    }

    func interface() -> AudioTranscriptBatcherScheduler {
        AudioTranscriptBatcherScheduler(
            now: { await self.currentDate },
            sleepUntil: { deadline in try await self.sleep(until: deadline) }
        )
    }

    func advance(by interval: TimeInterval) {
        advance(to: currentDate.addingTimeInterval(interval))
    }

    func advance(to date: Date) {
        currentDate = max(currentDate, date)
        let ready = waiters.filter { $0.value.deadline <= currentDate }
        for id in ready.keys { waiters.removeValue(forKey: id) }
        for waiter in ready.values { waiter.continuation.resume() }
    }

    private func sleep(until deadline: Date) async throws {
        let id = UUID()
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if deadline <= currentDate {
                    continuation.resume()
                } else {
                    waiters[id] = Waiter(deadline: deadline, continuation: continuation)
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }
}

private actor BlockingNowAudioBatcherScheduler {
    private let currentDate: Date
    private var isBlocked = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(now: Date) {
        currentDate = now
    }

    func interface() -> AudioTranscriptBatcherScheduler {
        AudioTranscriptBatcherScheduler(
            now: { await self.blockingNow() },
            sleepUntil: { _ in }
        )
    }

    func waitUntilNowBlocks() async {
        if isBlocked { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseNow() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    private func blockingNow() async -> Date {
        isBlocked = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return currentDate
    }
}

private func eventually(
    attempts: Int = 100,
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}
