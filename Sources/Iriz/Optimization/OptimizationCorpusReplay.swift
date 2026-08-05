import Foundation

@available(macOS 26.0, *)
struct OptimizationReplayCorpusCase: Sendable {
    let input: LocalGateInput
    let referenceCloudMeaningful: Bool
    let isCriticalCase: Bool

    init(
        input: LocalGateInput,
        referenceCloudMeaningful: Bool,
        isCriticalCase: Bool
    ) {
        self.input = input
        self.referenceCloudMeaningful = referenceCloudMeaningful
        self.isCriticalCase = isCriticalCase
    }
}

struct OptimizationReplayPhaseSummary: Codable, Equatable, Sendable {
    let phase: OptimizationPhase
    let corpusCount: Int
    let cloudRouteCount: Int
    let suppressedCloudCount: Int
    let falseRejectionCount: Int
    let criticalFalseRejectionCount: Int
    let cacheHitCount: Int
    let verdictCounts: [String: Int]
    let routeReasonCounts: [String: Int]
}

struct OptimizationCorpusReplayReport: Codable, Equatable, Sendable {
    static let currentSchemaVersion = "iriz-optimization-replay-v1"

    let schemaVersion: String
    let corpusCount: Int
    let phases: [OptimizationReplayPhaseSummary]
}

/// Replays the exact same ordered corpus through a fresh local gate per phase.
/// The runner has no OpenAI dependency and cannot issue a network request. The
/// caller injects a deterministic Foundation Models provider (or a test stub)
/// and supplies the historical cloud label with each corpus case.
@available(macOS 26.0, *)
struct OptimizationCorpusReplayRunner: Sendable {
    typealias GateFactory = @Sendable () -> any LocalGateRouting

    private let gateFactory: GateFactory

    init(gateFactory: @escaping GateFactory) {
        self.gateFactory = gateFactory
    }

    init(
        registry: AppleQualificationRegistry,
        providerFactory: @escaping @Sendable () -> any LocalGateModelProviding
    ) {
        self.gateFactory = {
            AppleFoundationModelGate(
                provider: providerFactory(),
                registry: registry,
                cacheTTL: 0
            )
        }
    }

    func replay(
        _ corpus: [OptimizationReplayCorpusCase],
        phases: [OptimizationPhase] = OptimizationPhase.allCases
    ) async -> OptimizationCorpusReplayReport {
        var summaries: [OptimizationReplayPhaseSummary] = []
        for phase in phases {
            let gate = gateFactory()
            var cloudRouteCount = 0
            var suppressedCloudCount = 0
            var falseRejectionCount = 0
            var criticalFalseRejectionCount = 0
            var cacheHitCount = 0
            var verdictCounts: [String: Int] = [:]
            var routeReasonCounts: [String: Int] = [:]

            for corpusCase in corpus {
                let decision = await gate.route(corpusCase.input, mode: phase.localGateMode)
                switch decision.route {
                case .useCloud:
                    cloudRouteCount += 1
                case .suppressCloud:
                    suppressedCloudCount += 1
                    if corpusCase.referenceCloudMeaningful {
                        falseRejectionCount += 1
                        if corpusCase.isCriticalCase {
                            criticalFalseRejectionCount += 1
                        }
                    }
                }
                if decision.fromCache { cacheHitCount += 1 }
                if let verdict = decision.verdict {
                    verdictCounts[verdict.rawValue, default: 0] += 1
                }
                routeReasonCounts[Self.reasonName(decision.reason), default: 0] += 1
            }

            summaries.append(OptimizationReplayPhaseSummary(
                phase: phase,
                corpusCount: corpus.count,
                cloudRouteCount: cloudRouteCount,
                suppressedCloudCount: suppressedCloudCount,
                falseRejectionCount: falseRejectionCount,
                criticalFalseRejectionCount: criticalFalseRejectionCount,
                cacheHitCount: cacheHitCount,
                verdictCounts: verdictCounts,
                routeReasonCounts: routeReasonCounts
            ))
        }
        return OptimizationCorpusReplayReport(
            schemaVersion: OptimizationCorpusReplayReport.currentSchemaVersion,
            corpusCount: corpus.count,
            phases: summaries
        )
    }

    private static func reasonName(_ reason: LocalGateDecisionReason) -> String {
        switch reason {
        case .gateDisabled: "gateDisabled"
        case .shadowMode: "shadowMode"
        case .meeting: "meeting"
        case .manualNote: "manualNote"
        case .retry: "retry"
        case .visualContextRequired: "visualContextRequired"
        case .insufficientText: "insufficientText"
        case .highRiskSignal: "highRiskSignal"
        case .unavailable(let availability): "unavailable:\(availabilityName(availability))"
        case .unqualifiedModel: "unqualifiedModel"
        case .clearlyEmpty: "clearlyEmpty"
        case .uncertain: "uncertain"
        case .meaningful: "meaningful"
        case .generationFailed: "generationFailed"
        }
    }

    private static func availabilityName(_ availability: LocalModelAvailability) -> String {
        switch availability {
        case .available: "available"
        case .unsupportedOperatingSystem: "unsupportedOperatingSystem"
        case .deviceNotEligible: "deviceNotEligible"
        case .appleIntelligenceNotEnabled: "appleIntelligenceNotEnabled"
        case .modelNotReady: "modelNotReady"
        case .unsupportedLocale: "unsupportedLocale"
        case .unknown: "unknown"
        }
    }
}
