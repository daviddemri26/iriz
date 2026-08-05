import Foundation

/// Registers producer callbacks synchronously before their async body can run.
/// This closes the shutdown race where an audio callback was created just as
/// termination took its in-flight snapshot.
final class AsyncCallbackTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var isAccepting = true

    func resumeAccepting() {
        lock.withLock { isAccepting = true }
    }

    func stopAccepting() {
        lock.withLock { isAccepting = false }
    }

    @discardableResult
    func submit(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never>? {
        let identifier = UUID()
        return lock.withLock {
            guard isAccepting else { return nil }
            let task = Task { [weak self] in
                guard !Task.isCancelled else {
                    self?.finish(identifier)
                    return
                }
                await operation()
                self?.finish(identifier)
            }
            // The lock remains held until insertion. A very short task can
            // finish immediately, but its removal waits behind this write.
            tasks[identifier] = task
            return task
        }
    }

    func drain(cancel: Bool) async {
        let active = lock.withLock {
            isAccepting = false
            return Array(tasks.values)
        }
        if cancel { active.forEach { $0.cancel() } }
        for task in active { await task.value }
    }

    private func finish(_ identifier: UUID) {
        _ = lock.withLock { tasks.removeValue(forKey: identifier) }
    }
}
