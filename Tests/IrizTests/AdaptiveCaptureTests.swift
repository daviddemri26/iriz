import CoreGraphics
import Foundation
import Testing
@testable import Iriz

@Suite("Adaptive screen capture")
struct AdaptiveCaptureTests {
    @Test("Legacy capture compares with every two-second sample")
    func legacyBaselineSemantics() {
        var policy = LegacyCapturePolicy()
        let context = makeContext(application: "Safari", title: "Document")
        let baseline = FrameSignature(pixels: [0, 0, 0, 0], digest: "baseline")
        let firstSmallChange = FrameSignature(pixels: [15, 15, 15, 15], digest: "small")
        let secondSmallChange = FrameSignature(pixels: [30, 30, 30, 30], digest: "second")

        let baselineDelivered = policy.register(signature: baseline, context: context)
        let firstDelivered = policy.register(signature: firstSmallChange, context: context)
        #expect(baselineDelivered)
        #expect(!firstDelivered)
        // Legacy advances to the ignored sample, so two small steps do not
        // accumulate as they do in the adaptive policy.
        let secondDelivered = policy.register(signature: secondSmallChange, context: context)
        #expect(!secondDelivered)
    }

    @Test("Capture starts active, backs off after three stable samples, and resumes on context change")
    func adaptiveCadence() {
        var policy = AdaptiveCapturePolicy()
        let signature = FrameSignature(pixels: [0, 0, 0, 0], digest: "initial")
        let safari = makeContext(application: "Safari", title: "Inbox")
        let mail = makeContext(application: "Mail", title: "Inbox")

        #expect(policy.nextInterval == .seconds(5))
        let initialDelivery = policy.register(signature: signature, context: safari)
        #expect(initialDelivery)
        let firstStableSample = policy.register(signature: signature, context: safari)
        #expect(!firstStableSample)
        #expect(policy.nextInterval == .seconds(5))
        let secondStableSample = policy.register(signature: signature, context: safari)
        #expect(!secondStableSample)
        #expect(policy.nextInterval == .seconds(5))
        let thirdStableSample = policy.register(signature: signature, context: safari)
        #expect(!thirdStableSample)
        #expect(policy.nextInterval == .seconds(10))

        let contextChange = policy.register(signature: signature, context: mail)
        #expect(contextChange)
        #expect(policy.nextInterval == .seconds(5))
    }

    @Test("Small changes accumulate against the last delivered frame")
    func accumulatedChanges() {
        var policy = AdaptiveCapturePolicy()
        let context = makeContext(application: "Safari", title: "Document")
        let baseline = FrameSignature(pixels: [0, 0, 0, 0], digest: "baseline")
        let firstSmallChange = FrameSignature(pixels: [15, 15, 15, 15], digest: "small")
        let accumulatedChange = FrameSignature(pixels: [20, 20, 20, 20], digest: "accumulated")

        let baselineDelivery = policy.register(signature: baseline, context: context)
        #expect(baselineDelivery)
        let firstDelivery = policy.register(signature: firstSmallChange, context: context)
        #expect(!firstDelivery)
        let accumulatedDelivery = policy.register(signature: accumulatedChange, context: context)
        #expect(accumulatedDelivery)
    }

    @Test("Reset makes the next available sample immediately deliverable")
    func resetAfterUnavailableContext() {
        var policy = AdaptiveCapturePolicy()
        let context = makeContext(application: "Safari", title: "Document")
        let signature = FrameSignature(pixels: [0, 0], digest: "same")

        let firstDelivery = policy.register(signature: signature, context: context)
        #expect(firstDelivery)
        let stableDelivery = policy.register(signature: signature, context: context)
        #expect(!stableDelivery)
        policy.reset()
        let deliveryAfterReset = policy.register(signature: signature, context: context)
        #expect(deliveryAfterReset)
        #expect(policy.nextInterval == .seconds(5))
    }

    @Test("A queued frame does not become the comparison baseline before dispatch")
    func queuedFrameDoesNotAdvanceBaseline() {
        var policy = AdaptiveCapturePolicy()
        let context = makeContext(application: "Safari", title: "Document")
        let delivered = FrameSignature(pixels: [0, 0, 0, 0], digest: "delivered")
        let queued = FrameSignature(pixels: [32, 32, 32, 32], digest: "queued")

        policy.recordDelivered(signature: delivered, context: context)
        #expect(policy.shouldDeliver(signature: queued, context: context))
        policy.recordPendingDelivery()

        // If the queued frame is evicted, a return to the actual delivered frame
        // is stable. Once dispatch is confirmed, that same return is significant.
        #expect(!policy.shouldDeliver(signature: delivered, context: context))
        policy.recordDelivered(signature: queued, context: context)
        #expect(policy.shouldDeliver(signature: delivered, context: context))
    }

    @Test("The async dispatcher keeps at most the three newest waiting frames")
    func boundedNonBlockingDispatch() async {
        let probe = CaptureDispatchProbe()
        let dispatcher = BoundedAsyncDispatcher<Int>(capacity: 3) { value in
            await probe.receive(value)
        }

        await dispatcher.submit(0)
        await probe.waitUntilFirstValueBlocks()
        await dispatcher.submit(1)
        await dispatcher.submit(2)
        await dispatcher.submit(3)
        await dispatcher.submit(4)
        await probe.releaseFirstValue()
        await probe.waitForCount(4)

        let values = await probe.values
        #expect(values == [0, 2, 3, 4])
    }

    @Test("Cancelling the dispatcher drops every frame still behind the privacy boundary")
    func cancellationDropsPendingFrames() async {
        let probe = CaptureDispatchProbe()
        let dispatcher = BoundedAsyncDispatcher<Int>(capacity: 3) { value in
            await probe.receive(value)
        }

        await dispatcher.submit(0)
        await probe.waitUntilFirstValueBlocks()
        await dispatcher.submit(1)
        await dispatcher.submit(2)
        await dispatcher.cancelPending()
        await probe.releaseFirstValue()
        try? await Task.sleep(for: .milliseconds(10))

        #expect(await probe.values == [0])
    }

    @Test("Cancel-and-wait never orphans a reentrant dispatcher drain")
    func cancellationPreservesNewGenerationDrain() async {
        let probe = SerialCaptureDispatchProbe()
        let dispatcher = BoundedAsyncDispatcher<Int>(capacity: 3) { value in
            await probe.receive(value)
        }

        await dispatcher.submit(0)
        await probe.waitUntilFirstValueBlocks()
        let firstFence = Task { await dispatcher.cancelPendingAndWait() }
        await probe.waitUntilFirstValueIsCancelled()
        await dispatcher.submit(1)
        await probe.releaseFirstValue()
        await probe.waitUntilSecondValueBlocks()
        await firstFence.value

        // If cancelAndWait erased the new drain reference, this submission would
        // start a second consumer while value 1 is still blocked.
        await dispatcher.submit(2)
        for _ in 0..<20 { await Task.yield() }
        #expect(await probe.maximumConcurrentHandlers == 1)
        #expect(await probe.values == [0, 1])

        let secondFence = Task { await dispatcher.cancelPendingAndWait() }
        await probe.waitUntilSecondValueIsCancelled()
        await probe.releaseSecondValue()
        await secondFence.value
        await dispatcher.submit(3)
        #expect(await probe.waitForValue(3))
        #expect(await probe.maximumConcurrentHandlers == 1)
    }

    @Test("Commitments, confirmations, dates, and meetings bypass the quiet debounce")
    func highRiskCaptureSignals() {
        let context = makeContext(application: "Safari", title: "Checkout")
        let meeting = ActiveContext(
            applicationName: "FaceTime",
            bundleIdentifier: "com.apple.FaceTime",
            windowTitle: "Weekly review",
            url: nil,
            isMeeting: true
        )

        #expect(ObservationRiskSignals.containsHighRiskSignal(
            text: "Payment confirmed — receipt 1942",
            context: context
        ))
        #expect(ObservationRiskSignals.containsHighRiskSignal(
            text: "The proposal is due tomorrow at 10:30",
            context: context
        ))
        #expect(ObservationRiskSignals.containsHighRiskSignal(text: "Routine discussion", context: meeting))
        #expect(!ObservationRiskSignals.containsHighRiskSignal(
            text: "Reading a product overview",
            context: context
        ))
    }

    @Test("Microphone admission fails closed during privacy transitions")
    func audioCaptureAdmission() {
        #expect(AudioCaptureAdmissionPolicy.allowsCapture(
            isPreparingForTermination: false,
            isPaused: false,
            screenVisibility: .available,
            privacyCleanupInProgress: false
        ))
        for visibility in [ScreenContextVisibility.private] {
            #expect(!AudioCaptureAdmissionPolicy.allowsCapture(
                isPreparingForTermination: false,
                isPaused: false,
                screenVisibility: visibility,
                privacyCleanupInProgress: false
            ))
        }
        #expect(!AudioCaptureAdmissionPolicy.allowsCapture(
            isPreparingForTermination: false,
            isPaused: true,
            screenVisibility: .available,
            privacyCleanupInProgress: false
        ))
        #expect(!AudioCaptureAdmissionPolicy.allowsCapture(
            isPreparingForTermination: false,
            isPaused: false,
            screenVisibility: .available,
            privacyCleanupInProgress: true
        ))
        #expect(!AudioCaptureAdmissionPolicy.allowsCapture(
            isPreparingForTermination: true,
            isPaused: false,
            screenVisibility: .available,
            privacyCleanupInProgress: false
        ))
        // An unavailable screen context is not private: ambient microphone work
        // remains valid while Accessibility or Screen Recording is recovered.
        #expect(AudioCaptureAdmissionPolicy.allowsCapture(
            isPreparingForTermination: false,
            isPaused: false,
            screenVisibility: .unavailable,
            privacyCleanupInProgress: false
        ))
        #expect(AudioCaptureAdmissionPolicy.allowsMeetingSystemAudio(
            isPreparingForTermination: false,
            isPaused: false,
            screenVisibility: .available,
            privacyCleanupInProgress: false,
            isMeetingContext: true,
            meetingDetectionEnabled: true,
            isAudioActiveNow: true
        ))
        for visibility in [ScreenContextVisibility.private, .unavailable] {
            #expect(!AudioCaptureAdmissionPolicy.allowsMeetingSystemAudio(
                isPreparingForTermination: false,
                isPaused: false,
                screenVisibility: visibility,
                privacyCleanupInProgress: false,
                isMeetingContext: true,
                meetingDetectionEnabled: true,
                isAudioActiveNow: true
            ))
        }
    }

    @Test("Meeting audio identity rotates between meetings but ignores window geometry")
    func meetingContextIdentity() {
        let first = ActiveContext(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            windowTitle: "Customer review",
            url: URL(string: "https://meet.example.com/room-a?participant=1"),
            isMeeting: true,
            processIdentifier: 101,
            windowFrame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        let resized = ActiveContext(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            windowTitle: "  CUSTOMER   review ",
            url: URL(string: "https://meet.example.com/room-a?participant=2"),
            isMeeting: true,
            processIdentifier: 101,
            windowFrame: CGRect(x: 20, y: 30, width: 1200, height: 800)
        )
        let second = ActiveContext(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            windowTitle: "Customer review",
            url: URL(string: "https://meet.example.com/room-b"),
            isMeeting: true
        )

        #expect(MeetingContextIdentity(first) == MeetingContextIdentity(resized))
        #expect(MeetingContextIdentity(first) != MeetingContextIdentity(second))
        #expect(MeetingContextIdentity(ActiveContext(isMeeting: false)) == nil)
    }

    @Test("Batched OCR text is bounded without splitting the separator budget")
    func boundedBatchText() {
        let joined = ScreenObservationBatcher.joinedText(
            ["First distinct screen", "Second distinct screen"],
            limit: 24
        )

        #expect(joined.count <= 24)
        #expect(joined.hasPrefix("First distinct screen"))
    }

    @Test("Screen OCR batches flush after ten seconds of calm")
    func screenBatchQuietFlush() async throws {
        let ocr = ScreenOCRProbe(outputs: ["Drafting the quarterly plan"])
        let output = ScreenBatchProbe()
        let batcher = ScreenObservationBatcher(
            ocr: ocr,
            tuning: .init(
                quietInterval: 0.01,
                hardFlushInterval: 30,
                duplicateWindow: 15 * 60,
                maximumPendingFrames: 3,
                maximumTextCharacters: 12_000
            )
        )
        await batcher.start { batch in await output.receive(batch) }

        await batcher.submit(makeFrame(textID: "quiet", capturedAt: Date()))
        #expect(await waitForScreenBatchCount(1, in: output))
        let batches = await output.values
        #expect(batches.first?.text == "Drafting the quarterly plan")
    }

    @Test("Screen OCR hard-flushes accumulated changes after thirty seconds")
    func screenBatchHardFlush() async throws {
        let startedAt = Date()
        let ocr = ScreenOCRProbe(outputs: ["First research excerpt", "Second research excerpt"])
        let output = ScreenBatchProbe()
        let batcher = ScreenObservationBatcher(
            ocr: ocr,
            tuning: .init(quietInterval: 10, hardFlushInterval: 30)
        )
        await batcher.start { batch in await output.receive(batch) }

        await batcher.submit(makeFrame(textID: "first", capturedAt: startedAt))
        #expect(await waitForOCRCount(1, in: ocr))
        await batcher.submit(makeFrame(textID: "second", capturedAt: startedAt.addingTimeInterval(31)))

        #expect(await waitForScreenBatchCount(1, in: output))
        let batches = await output.values
        #expect(batches.first?.text.contains("First research excerpt") == true)
        #expect(batches.first?.text.contains("Second research excerpt") == true)
    }

    @Test("Screen OCR hard deadline is not extended by the last quiet debounce")
    func screenBatchTimerHonorsHardDeadline() async throws {
        let startedAt = Date()
        let ocr = ScreenOCRProbe(outputs: ["First excerpt", "Last excerpt"])
        let output = ScreenBatchProbe()
        let batcher = ScreenObservationBatcher(
            ocr: ocr,
            tuning: .init(quietInterval: 0.10, hardFlushInterval: 0.03)
        )
        await batcher.start { batch in await output.receive(batch) }

        await batcher.submit(makeFrame(textID: "first", capturedAt: startedAt))
        #expect(await waitForOCRCount(1, in: ocr))
        await batcher.submit(makeFrame(
            textID: "last",
            capturedAt: startedAt.addingTimeInterval(0.025)
        ))

        #expect(await waitForScreenBatchCount(1, in: output, attempts: 80))
        #expect(await output.values.first?.text.contains("Last excerpt") == true)
    }

    @Test("A screen context change flushes the previous OCR batch")
    func screenBatchContextChange() async throws {
        let ocr = ScreenOCRProbe(outputs: ["Safari research", "Mail draft"])
        let output = ScreenBatchProbe()
        let batcher = ScreenObservationBatcher(
            ocr: ocr,
            tuning: .init(quietInterval: 10, hardFlushInterval: 30)
        )
        await batcher.start { batch in await output.receive(batch) }

        await batcher.submit(makeFrame(textID: "safari", capturedAt: Date()))
        #expect(await waitForOCRCount(1, in: ocr))
        await batcher.submit(makeFrame(
            textID: "mail",
            capturedAt: Date().addingTimeInterval(1),
            context: makeContext(application: "Mail", title: "Draft")
        ))

        #expect(await waitForScreenBatchCount(1, in: output))
        #expect(await output.values.first?.text == "Safari research")
    }

    @Test("Identical normalized OCR is suppressed for fifteen minutes")
    func screenBatchDeduplication() async throws {
        let now = Date()
        let ocr = ScreenOCRProbe(outputs: ["Same useful text", "  SAME useful   text  "])
        let output = ScreenBatchProbe()
        let batcher = ScreenObservationBatcher(
            ocr: ocr,
            tuning: .init(quietInterval: 10, hardFlushInterval: 30, duplicateWindow: 15 * 60)
        )
        await batcher.start { batch in await output.receive(batch) }

        await batcher.submit(makeFrame(textID: "one", capturedAt: now))
        #expect(await waitForOCRCount(1, in: ocr))
        await batcher.flush()
        #expect(await waitForScreenBatchCount(1, in: output))
        await batcher.submit(makeFrame(textID: "two", capturedAt: now.addingTimeInterval(60)))
        #expect(await waitForOCRCount(2, in: ocr))
        await batcher.flush()

        #expect(await output.values.count == 1)
    }

    @Test("Cancelling screen OCR drops queued and in-flight private work")
    func screenBatchCancellation() async throws {
        let ocr = ScreenOCRProbe(outputs: ["Private draft"], delay: .milliseconds(40))
        let output = ScreenBatchProbe()
        let batcher = ScreenObservationBatcher(
            ocr: ocr,
            tuning: .init(quietInterval: 0.01, hardFlushInterval: 30)
        )
        await batcher.start { batch in await output.receive(batch) }

        await batcher.submit(makeFrame(textID: "private", capturedAt: Date()))
        await batcher.cancel()
        try await Task.sleep(for: .milliseconds(70))

        #expect(await output.values.isEmpty)
    }

    @Test("Cancellation fences an emission suspended in telemetry")
    func screenBatchCancellationDuringTelemetry() async {
        let ocr = ScreenOCRProbe(outputs: ["Payment confirmed — private receipt"])
        let output = ScreenBatchProbe()
        let telemetry = BlockingScreenBatchTelemetryProbe()
        let batcher = ScreenObservationBatcher(
            ocr: ocr,
            tuning: .init(quietInterval: 10, hardFlushInterval: 30)
        )
        await batcher.start(
            telemetryHandler: { record in await telemetry.receive(record) },
            handler: { batch in await output.receive(batch) }
        )

        let submission = Task {
            await batcher.submit(makeFrame(textID: "private-risk", capturedAt: Date()))
        }
        await telemetry.waitUntilEmissionTelemetryBlocks()
        let generation = await batcher.cancellationGenerationForTesting()
        let cancellation = Task { await batcher.cancelAndDrain() }
        #expect(await waitForScreenBatcherCancellation(after: generation, in: batcher))
        await telemetry.releaseEmissionTelemetry()
        await submission.value
        await cancellation.value

        #expect(await output.values.isEmpty)
    }

    @Test("A high-risk OCR signal bypasses the quiet screen debounce")
    func screenBatchHighRiskFlush() async throws {
        let ocr = ScreenOCRProbe(outputs: ["Payment confirmed — receipt 1942"])
        let output = ScreenBatchProbe()
        let batcher = ScreenObservationBatcher(
            ocr: ocr,
            tuning: .init(quietInterval: 10, hardFlushInterval: 30)
        )
        await batcher.start { batch in await output.receive(batch) }

        await batcher.submit(makeFrame(textID: "risk", capturedAt: Date()))

        #expect(await waitForScreenBatchCount(1, in: output))
        #expect(await output.values.first?.containsHighRiskSignal == true)
    }

    private func makeContext(application: String, title: String) -> ActiveContext {
        ActiveContext(
            applicationName: application,
            bundleIdentifier: "com.example.\(application.lowercased())",
            windowTitle: title,
            url: nil,
            isMeeting: false
        )
    }

    private func makeFrame(
        textID: String,
        capturedAt: Date,
        context: ActiveContext? = nil
    ) -> CapturedScreenFrame {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmap = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return CapturedScreenFrame(
            image: bitmap.makeImage()!,
            jpegData: Data(textID.utf8),
            signature: FrameSignature(pixels: [0], digest: textID),
            context: context ?? makeContext(application: "Safari", title: "Document"),
            capturedAt: capturedAt,
            significantChange: true
        )
    }
}

private actor ScreenOCRProbe: ScreenOCRProviding {
    private var outputs: [String]
    private let delay: Duration?
    private(set) var callCount = 0

    init(outputs: [String], delay: Duration? = nil) {
        self.outputs = outputs
        self.delay = delay
    }

    func recognizeText(in image: CGImage) async throws -> String {
        callCount += 1
        if let delay { try await Task.sleep(for: delay) }
        return outputs.isEmpty ? "" : outputs.removeFirst()
    }
}

private actor ScreenBatchProbe {
    private(set) var values: [BatchedScreenObservation] = []

    func receive(_ batch: BatchedScreenObservation) {
        values.append(batch)
    }
}

private actor BlockingScreenBatchTelemetryProbe {
    private var isBlocked = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func receive(_ record: OptimizationTelemetryRecord) async {
        guard record.metric == .batchEmitted else { return }
        isBlocked = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilEmissionTelemetryBlocks() async {
        if isBlocked { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseEmissionTelemetry() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private func waitForScreenBatchCount(
    _ count: Int,
    in probe: ScreenBatchProbe,
    attempts: Int = 200
) async -> Bool {
    for _ in 0..<attempts {
        if await probe.values.count >= count { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return false
}

private func waitForOCRCount(
    _ count: Int,
    in probe: ScreenOCRProbe,
    attempts: Int = 200
) async -> Bool {
    for _ in 0..<attempts {
        if await probe.callCount >= count { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return false
}

private func waitForScreenBatcherCancellation(
    after generation: Int,
    in batcher: ScreenObservationBatcher,
    attempts: Int = 200
) async -> Bool {
    for _ in 0..<attempts {
        if await batcher.cancellationGenerationForTesting() > generation { return true }
        await Task.yield()
    }
    return false
}

private actor CaptureDispatchProbe {
    private(set) var values: [Int] = []
    private var firstValueIsBlocked = false
    private var firstValueBlockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var countWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func receive(_ value: Int) async {
        values.append(value)
        resumeSatisfiedWaiters()

        guard value == 0 else { return }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
            firstValueIsBlocked = true
            firstValueBlockedWaiters.forEach { $0.resume() }
            firstValueBlockedWaiters.removeAll()
        }
    }

    func waitUntilFirstValueBlocks() async {
        if firstValueIsBlocked { return }
        await withCheckedContinuation { continuation in
            firstValueBlockedWaiters.append(continuation)
        }
    }

    func releaseFirstValue() {
        releaseContinuation?.resume()
        releaseContinuation = nil
        firstValueIsBlocked = false
    }

    func waitForCount(_ count: Int) async {
        if values.count >= count { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((count, continuation))
        }
    }

    private func resumeSatisfiedWaiters() {
        let satisfied = countWaiters.filter { values.count >= $0.count }
        countWaiters.removeAll { values.count >= $0.count }
        satisfied.forEach { $0.continuation.resume() }
    }
}

private actor SerialCaptureDispatchProbe {
    private(set) var values: [Int] = []
    private(set) var maximumConcurrentHandlers = 0
    private var concurrentHandlers = 0
    private var firstBlocked = false
    private var secondBlocked = false
    private var firstCancelled = false
    private var secondCancelled = false
    private var firstStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var secondStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstCancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var secondCancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstRelease: CheckedContinuation<Void, Never>?
    private var secondRelease: CheckedContinuation<Void, Never>?

    func receive(_ value: Int) async {
        concurrentHandlers += 1
        maximumConcurrentHandlers = max(maximumConcurrentHandlers, concurrentHandlers)
        values.append(value)
        defer { concurrentHandlers -= 1 }

        switch value {
        case 0:
            firstBlocked = true
            firstStartWaiters.forEach { $0.resume() }
            firstStartWaiters.removeAll()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    firstRelease = continuation
                }
            } onCancel: {
                Task { await self.markFirstCancelled() }
            }
        case 1:
            secondBlocked = true
            secondStartWaiters.forEach { $0.resume() }
            secondStartWaiters.removeAll()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    secondRelease = continuation
                }
            } onCancel: {
                Task { await self.markSecondCancelled() }
            }
        default:
            break
        }
    }

    func waitUntilFirstValueBlocks() async {
        if firstBlocked { return }
        await withCheckedContinuation { firstStartWaiters.append($0) }
    }

    func waitUntilSecondValueBlocks() async {
        if secondBlocked { return }
        await withCheckedContinuation { secondStartWaiters.append($0) }
    }

    func waitUntilFirstValueIsCancelled() async {
        if firstCancelled { return }
        await withCheckedContinuation { firstCancellationWaiters.append($0) }
    }

    func waitUntilSecondValueIsCancelled() async {
        if secondCancelled { return }
        await withCheckedContinuation { secondCancellationWaiters.append($0) }
    }

    func releaseFirstValue() {
        firstRelease?.resume()
        firstRelease = nil
    }

    func releaseSecondValue() {
        secondRelease?.resume()
        secondRelease = nil
    }

    func waitForValue(_ value: Int, attempts: Int = 200) async -> Bool {
        for _ in 0..<attempts {
            if values.contains(value) { return true }
            await Task.yield()
        }
        return false
    }

    private func markFirstCancelled() {
        firstCancelled = true
        firstCancellationWaiters.forEach { $0.resume() }
        firstCancellationWaiters.removeAll()
    }

    private func markSecondCancelled() {
        secondCancelled = true
        secondCancellationWaiters.forEach { $0.resume() }
        secondCancellationWaiters.removeAll()
    }
}
