import Foundation
import Testing
@testable import Iriz

@Suite("Async callback shutdown tracking")
struct AsyncCallbackTrackerTests {
    @Test("Drain waits for every synchronously registered callback and closes admission")
    func drainWaitsAndClosesAdmission() async {
        let tracker = AsyncCallbackTracker()
        let probe = BlockingCallbackProbe()
        let registered = tracker.submit {
            await probe.run()
        }
        #expect(registered != nil)
        await probe.waitUntilStarted()

        let drain = Task { await tracker.drain(cancel: false) }
        await Task.yield()
        #expect(!(await probe.finished))
        await probe.release()
        await drain.value
        #expect(await probe.finished)

        let rejected = tracker.submit { await probe.markUnexpectedAdmission() }
        #expect(rejected == nil)
        await Task.yield()
        #expect(!(await probe.unexpectedAdmission))
    }
}

private actor BlockingCallbackProbe {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private(set) var finished = false
    private(set) var unexpectedAdmission = false

    func run() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        finished = true
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func markUnexpectedAdmission() {
        unexpectedAdmission = true
    }
}
