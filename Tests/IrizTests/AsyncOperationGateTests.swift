import Foundation
import Testing
@testable import Iriz

@Suite("Serialized analysis persistence")
struct AsyncOperationGateTests {
    @Test("A second mutation cannot enter before the first releases")
    @MainActor
    func serializesReentrantWorkflows() async {
        let gate = AsyncOperationGate()
        let probe = OperationGateProbe()
        await gate.acquire()

        let second = Task { @MainActor in
            await gate.acquire()
            await probe.markEntered()
            gate.release()
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(!(await probe.entered))

        gate.release()
        await second.value
        #expect(await probe.entered)
    }
}

private actor OperationGateProbe {
    private(set) var entered = false

    func markEntered() {
        entered = true
    }
}
