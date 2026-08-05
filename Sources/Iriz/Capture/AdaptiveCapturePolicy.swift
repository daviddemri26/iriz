import Foundation

enum CaptureCommitDomain: Hashable, Sendable {
    case screen
    case audio
}

/// Linearization fence shared by privacy-boundary invalidation and the final
/// SQLite analysis transaction. A boundary either happens before the commit
/// (the authorization is rejected) or after the complete transaction; it can
/// never interleave between the last AppState check and durable persistence.
final class CaptureCommitFence: @unchecked Sendable {
    private let lock = NSLock()
    private var generations: [CaptureCommitDomain: UInt64] = [
        .screen: 0,
        .audio: 0
    ]

    func authorization(for domain: CaptureCommitDomain) -> CaptureCommitAuthorization {
        lock.lock()
        let generation = generations[domain, default: 0]
        lock.unlock()
        return CaptureCommitAuthorization(fence: self, domain: domain, generation: generation)
    }

    func invalidate(_ domains: Set<CaptureCommitDomain>) {
        guard !domains.isEmpty else { return }
        lock.lock()
        for domain in domains {
            generations[domain, default: 0] &+= 1
        }
        lock.unlock()
    }

    fileprivate func perform<T>(
        domain: CaptureCommitDomain,
        generation: UInt64,
        operation: () throws -> T
    ) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard generations[domain, default: 0] == generation else {
            throw CancellationError()
        }
        return try operation()
    }
}

struct CaptureCommitAuthorization: @unchecked Sendable {
    fileprivate let fence: CaptureCommitFence
    fileprivate let domain: CaptureCommitDomain
    fileprivate let generation: UInt64

    func perform<T>(_ operation: () throws -> T) throws -> T {
        try fence.perform(domain: domain, generation: generation, operation: operation)
    }
}

/// Monotonic token used at every pause/private boundary. Restoring an
/// available context never rewinds the generation, so work that crossed the
/// boundary cannot become valid again after a quick private -> available flip.
struct CapturePrivacyBoundary: Sendable {
    private(set) var generation: UInt64 = 0

    var token: UInt64 { generation }

    mutating func invalidate() {
        generation &+= 1
    }

    func accepts(_ token: UInt64) -> Bool {
        token == generation
    }
}

/// Exact pre-optimization sampling behavior used by RC Baseline and rollback:
/// every sample becomes the next visual baseline and cadence stays at 2 seconds.
struct LegacyCapturePolicy: Sendable {
    private var previousSignature: FrameSignature?
    private var previousContext: ActiveContext?

    mutating func register(signature: FrameSignature, context: ActiveContext) -> Bool {
        let difference = FrameDiffer.difference(from: previousSignature, to: signature)
        let contextChanged = previousContext.map { $0 != context } ?? true
        previousSignature = signature
        previousContext = context
        return contextChanged || difference >= 0.075
    }

    mutating func reset() {
        previousSignature = nil
        previousContext = nil
    }
}

/// Tracks capture cadence and visual significance against the last frame that
/// was emitted to the processing pipeline. Ignored samples never replace the
/// comparison baseline, so several small changes can accumulate into one
/// meaningful delivery.
struct AdaptiveCapturePolicy: Sendable {
    struct Configuration: Sendable {
        var activeInterval: Duration = .seconds(5)
        var stableInterval: Duration = .seconds(10)
        var stableSamplesBeforeBackoff = 3
        var significantDifferenceThreshold = 0.075
    }

    private let configuration: Configuration
    private var lastDeliveredSignature: FrameSignature?
    private var lastDeliveredContext: ActiveContext?
    private(set) var consecutiveStableSamples = 0

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    var nextInterval: Duration {
        consecutiveStableSamples >= configuration.stableSamplesBeforeBackoff
            ? configuration.stableInterval
            : configuration.activeInterval
    }

    func shouldDeliver(signature: FrameSignature, context: ActiveContext) -> Bool {
        let difference = FrameDiffer.difference(from: lastDeliveredSignature, to: signature)
        let contextChanged = lastDeliveredContext.map { $0 != context } ?? true
        return contextChanged || difference >= configuration.significantDifferenceThreshold
    }

    mutating func recordDelivered(signature: FrameSignature, context: ActiveContext) {
        lastDeliveredSignature = signature
        lastDeliveredContext = context
        consecutiveStableSamples = 0
    }

    /// A significant frame is active work even while it is only waiting in the
    /// bounded dispatcher. Reset cadence without moving the comparison baseline;
    /// a frame that is later evicted must never become the delivered reference.
    mutating func recordPendingDelivery() {
        consecutiveStableSamples = 0
    }

    mutating func recordStableSample() {
        consecutiveStableSamples = min(
            consecutiveStableSamples + 1,
            configuration.stableSamplesBeforeBackoff
        )
    }

    /// Convenience used by deterministic tests and other producers that can
    /// emit immediately after making the decision.
    mutating func register(signature: FrameSignature, context: ActiveContext) -> Bool {
        let shouldDeliver = shouldDeliver(signature: signature, context: context)
        if shouldDeliver {
            recordDelivered(signature: signature, context: context)
        } else {
            recordStableSample()
        }
        return shouldDeliver
    }

    mutating func reset() {
        lastDeliveredSignature = nil
        lastDeliveredContext = nil
        consecutiveStableSamples = 0
    }
}
