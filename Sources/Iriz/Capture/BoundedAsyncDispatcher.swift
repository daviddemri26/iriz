import Foundation

struct BoundedDispatchSubmission: Equatable, Sendable {
    let droppedCount: Int
    let pendingDepth: Int
}

/// Runs a slow async consumer independently from its producer. When the
/// producer outruns the consumer, the oldest waiting value is discarded so
/// the bounded queue continues to represent the most recent screen context.
actor BoundedAsyncDispatcher<Element: Sendable> {
    typealias Handler = @Sendable (Element) async -> Void

    private let capacity: Int
    private let handler: Handler
    private var pending: [Element] = []
    private var drainTask: Task<Void, Never>?
    private var generation = 0

    init(capacity: Int, handler: @escaping Handler) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.handler = handler
    }

    @discardableResult
    func submit(_ element: Element) -> BoundedDispatchSubmission {
        var droppedCount = 0
        if pending.count == capacity {
            pending.removeFirst()
            droppedCount = 1
        }
        pending.append(element)
        let submission = BoundedDispatchSubmission(
            droppedCount: droppedCount,
            pendingDepth: pending.count
        )
        startDrainingIfNeeded()
        return submission
    }

    func cancelPending() {
        generation += 1
        pending.removeAll(keepingCapacity: true)
        drainTask?.cancel()
    }

    func cancelPendingAndWait() async {
        generation += 1
        pending.removeAll(keepingCapacity: true)
        let task = drainTask
        task?.cancel()
        await task?.value
        // The cancelled drain owns its generation cleanup. While this await is
        // suspended it may already have installed a new-generation drain for a
        // reentrant submission; clearing the property here would orphan that
        // consumer and allow a second concurrent drain to start.
    }

    private func startDrainingIfNeeded() {
        guard drainTask == nil else { return }
        let activeGeneration = generation
        drainTask = Task { [weak self] in
            await self?.drain(generation: activeGeneration)
        }
    }

    private func drain(generation activeGeneration: Int) async {
        while !Task.isCancelled, generation == activeGeneration, !pending.isEmpty {
            let next = pending.removeFirst()
            await handler(next)
        }

        guard generation == activeGeneration else {
            drainTask = nil
            if !pending.isEmpty { startDrainingIfNeeded() }
            return
        }
        drainTask = nil
        if !pending.isEmpty {
            startDrainingIfNeeded()
        }
    }
}
