import Foundation

enum AppleShadowVerdict: String, Codable, CaseIterable, Sendable {
    case clearlyEmpty
    case uncertain
    case meaningful
}

enum AppleShadowRouteReason: String, Codable, CaseIterable, Sendable {
    case gateDisabled
    case shadowMode
    case meeting
    case manualNote
    case retry
    case visualContextRequired
    case insufficientText
    case highRiskSignal
    case unavailable
    case unqualifiedModel
    case clearlyEmpty
    case uncertain
    case meaningful
    case generationFailed
}

/// Persisted independently from Foundation Models types so older encrypted
/// qualification records remain decodable if the local schema changes.
enum AppleShadowLocalEventOutcome: String, Codable, CaseIterable, Sendable {
    case notAttempted
    case unqualifiedModel
    case generated
    case rejectedOutput
    case generationFailed

    var isQualificationAttempt: Bool {
        switch self {
        case .generated, .rejectedOutput, .generationFailed: true
        case .notAttempted, .unqualifiedModel: false
        }
    }
}

/// Encrypted RC-only comparison data. `exampleText` is populated solely for a
/// disagreement in Development/RC builds; it is never part of operational
/// telemetry and is purged with the 30-day detail window.
struct AppleShadowQualificationRecord: Codable, Equatable, Sendable {
    let id: UUID
    let observationID: UUID
    let occurredAt: Date
    let modelFingerprint: AppleModelFingerprint?
    let verdict: AppleShadowVerdict?
    let routeReason: AppleShadowRouteReason
    let localLatencyMilliseconds: Int
    let generationAttempted: Bool
    /// Cache hits are useful operationally, but cannot qualify the warm model
    /// latency or structured-generation validity of a model fingerprint.
    let fromCache: Bool
    let structuredOutputValid: Bool
    let cloudMeaningful: Bool
    let isCriticalCase: Bool
    let falseRejection: Bool
    /// The draft capability is qualified separately from the routing gate.
    let localEventOutcome: AppleShadowLocalEventOutcome
    let localEventLatencyMilliseconds: Int?
    /// Set only for a generated draft. This deliberately requires the cloud
    /// interpretation to describe the same low-risk observed-event envelope.
    let localEventCloudCompatible: Bool?
    /// A generated local event must never conceal a cloud-detected Action,
    /// deadline, completion, meeting, purchase, confirmation, or decision.
    let localEventCriticalMismatch: Bool
    /// Defense-in-depth signal. Validated generated drafts should make this
    /// impossible; any non-zero value blocks capability promotion.
    let localEventSafetyViolation: Bool
    let exampleText: String?

    init(
        id: UUID = UUID(),
        observationID: UUID,
        occurredAt: Date = Date(),
        modelFingerprint: AppleModelFingerprint?,
        verdict: AppleShadowVerdict?,
        routeReason: AppleShadowRouteReason,
        localLatencyMilliseconds: Int,
        generationAttempted: Bool,
        fromCache: Bool = false,
        structuredOutputValid: Bool,
        cloudMeaningful: Bool,
        isCriticalCase: Bool,
        localEventOutcome: AppleShadowLocalEventOutcome = .notAttempted,
        localEventLatencyMilliseconds: Int? = nil,
        localEventCloudCompatible: Bool? = nil,
        localEventCriticalMismatch: Bool = false,
        localEventSafetyViolation: Bool = false,
        exampleText: String?
    ) {
        self.id = id
        self.observationID = observationID
        self.occurredAt = occurredAt
        self.modelFingerprint = modelFingerprint
        self.verdict = verdict
        self.routeReason = routeReason
        self.localLatencyMilliseconds = max(0, localLatencyMilliseconds)
        self.generationAttempted = generationAttempted
        self.fromCache = fromCache
        self.structuredOutputValid = structuredOutputValid
        self.cloudMeaningful = cloudMeaningful
        self.isCriticalCase = isCriticalCase
        self.falseRejection = verdict == .clearlyEmpty && cloudMeaningful
        self.localEventOutcome = localEventOutcome
        self.localEventLatencyMilliseconds = localEventLatencyMilliseconds.map { max(0, $0) }
        self.localEventCloudCompatible = localEventCloudCompatible
        self.localEventCriticalMismatch = localEventCriticalMismatch
        self.localEventSafetyViolation = localEventSafetyViolation
        self.exampleText = exampleText.map { String($0.prefix(12_000)) }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case observationID
        case occurredAt
        case modelFingerprint
        case verdict
        case routeReason
        case localLatencyMilliseconds
        case generationAttempted
        case fromCache
        case structuredOutputValid
        case cloudMeaningful
        case isCriticalCase
        case falseRejection
        case localEventOutcome
        case localEventLatencyMilliseconds
        case localEventCloudCompatible
        case localEventCriticalMismatch
        case localEventSafetyViolation
        case exampleText
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        observationID = try values.decode(UUID.self, forKey: .observationID)
        occurredAt = try values.decode(Date.self, forKey: .occurredAt)
        modelFingerprint = try values.decodeIfPresent(AppleModelFingerprint.self, forKey: .modelFingerprint)
        verdict = try values.decodeIfPresent(AppleShadowVerdict.self, forKey: .verdict)
        routeReason = try values.decode(AppleShadowRouteReason.self, forKey: .routeReason)
        localLatencyMilliseconds = max(0, try values.decode(Int.self, forKey: .localLatencyMilliseconds))
        generationAttempted = try values.decode(Bool.self, forKey: .generationAttempted)
        // Records written before qualification schema v2 were always treated as
        // uncached. Preserve that behavior while making future reports accurate.
        fromCache = try values.decodeIfPresent(Bool.self, forKey: .fromCache) ?? false
        structuredOutputValid = try values.decode(Bool.self, forKey: .structuredOutputValid)
        cloudMeaningful = try values.decode(Bool.self, forKey: .cloudMeaningful)
        isCriticalCase = try values.decode(Bool.self, forKey: .isCriticalCase)
        falseRejection = try values.decodeIfPresent(Bool.self, forKey: .falseRejection)
            ?? (verdict == .clearlyEmpty && cloudMeaningful)
        localEventOutcome = try values.decodeIfPresent(
            AppleShadowLocalEventOutcome.self,
            forKey: .localEventOutcome
        ) ?? .notAttempted
        localEventLatencyMilliseconds = try values.decodeIfPresent(Int.self, forKey: .localEventLatencyMilliseconds)
            .map { max(0, $0) }
        localEventCloudCompatible = try values.decodeIfPresent(Bool.self, forKey: .localEventCloudCompatible)
        localEventCriticalMismatch = try values.decodeIfPresent(Bool.self, forKey: .localEventCriticalMismatch) ?? false
        localEventSafetyViolation = try values.decodeIfPresent(Bool.self, forKey: .localEventSafetyViolation) ?? false
        exampleText = try values.decodeIfPresent(String.self, forKey: .exampleText)
            .map { String($0.prefix(12_000)) }
    }
}

struct AppleQualificationReport: Equatable, Sendable {
    let modelFingerprint: AppleModelFingerprint
    let observationCount: Int
    /// Observations for which Apple returned a typed routing verdict. Bypasses
    /// (meetings, risk signals, manual notes, and unavailable models) do not
    /// enter the gate error denominator.
    let gateDecisionCount: Int
    let meaningfulObservationCount: Int
    let criticalCaseCount: Int
    let criticalBypassViolationCount: Int
    let falseRejectionCount: Int
    let criticalFalseRejectionCount: Int
    let structuredGenerationCount: Int
    let validStructuredGenerationCount: Int
    let cacheHitCount: Int
    let warmLatencyP95Milliseconds: Int?
    let localEventAttemptCount: Int
    let validLocalEventGenerationCount: Int
    let localEventCloudCompatibleCount: Int
    let localEventCriticalMismatchCount: Int
    let localEventSafetyViolationCount: Int
    let localEventLatencyP95Milliseconds: Int?

    var falseRejectionRate: Double {
        guard gateDecisionCount > 0 else { return 0 }
        return Double(falseRejectionCount) / Double(gateDecisionCount)
    }

    var structuredValidityRate: Double {
        guard structuredGenerationCount > 0 else { return 0 }
        return Double(validStructuredGenerationCount) / Double(structuredGenerationCount)
    }

    var localEventValidityRate: Double {
        guard localEventAttemptCount > 0 else { return 0 }
        return Double(validLocalEventGenerationCount) / Double(localEventAttemptCount)
    }

    var localEventCloudCompatibilityRate: Double {
        guard validLocalEventGenerationCount > 0 else { return 0 }
        return Double(localEventCloudCompatibleCount) / Double(validLocalEventGenerationCount)
    }

    var qualifiesGate: Bool {
        observationCount >= 1_000
            && gateDecisionCount >= 1_000
            && meaningfulObservationCount >= 200
            && criticalCaseCount >= 100
            && criticalBypassViolationCount == 0
            && falseRejectionRate <= 0.005
            && criticalFalseRejectionCount == 0
            && structuredGenerationCount >= 1_000
            && structuredValidityRate >= 0.995
            && (warmLatencyP95Milliseconds ?? .max) < 1_500
    }

    /// Local events have their own promotion decision. Gate qualification is a
    /// prerequisite because both capabilities share the same approved model
    /// fingerprint, prompt version, and safety bypasses.
    var qualifiesLocalEvents: Bool {
        qualifiesGate
            && localEventAttemptCount >= 200
            && localEventValidityRate >= 0.995
            && localEventCloudCompatibilityRate >= 0.95
            && localEventCriticalMismatchCount == 0
            && localEventSafetyViolationCount == 0
            && (localEventLatencyP95Milliseconds ?? .max) < 1_500
    }
}

enum AppleQualificationEvaluationError: Error, Equatable, Sendable {
    case missingModelFingerprint
    case mixedModelFingerprints
}

enum AppleQualificationEvaluator {
    static func report(for records: [AppleShadowQualificationRecord]) throws -> AppleQualificationReport {
        // A record without a fingerprint cannot be attributed to a qualified
        // Apple model/runtime combination. Exclude it before every denominator,
        // safety counter, latency calculation, and promotion decision.
        let eligibleRecords = records.filter { $0.modelFingerprint != nil }
        let fingerprints = Set(eligibleRecords.compactMap(\.modelFingerprint))
        guard let fingerprint = fingerprints.first else {
            throw AppleQualificationEvaluationError.missingModelFingerprint
        }
        guard fingerprints.count == 1 else {
            throw AppleQualificationEvaluationError.mixedModelFingerprints
        }
        let gateDecisions = eligibleRecords.filter { $0.generationAttempted && $0.verdict != nil }
        let generations = eligibleRecords.filter { $0.generationAttempted && !$0.fromCache }
        // AppState prewarms before capture starts, so recorded generations are
        // the warm-path population. Cache hits are excluded because they do not
        // measure model latency. Keep uncached failures in the distribution.
        let warmLatencies = generations.map(\.localLatencyMilliseconds).sorted()
        let p95: Int? = if warmLatencies.isEmpty {
            nil
        } else {
            warmLatencies[min(warmLatencies.count - 1, Int(ceil(Double(warmLatencies.count) * 0.95)) - 1)]
        }
        let localEventAttempts = eligibleRecords.filter { $0.localEventOutcome.isQualificationAttempt }
        let localEventLatencies = localEventAttempts.compactMap(\.localEventLatencyMilliseconds).sorted()
        let localEventP95: Int? = if localEventLatencies.count != localEventAttempts.count
            || localEventLatencies.isEmpty {
            nil
        } else {
            localEventLatencies[
                min(
                    localEventLatencies.count - 1,
                    Int(ceil(Double(localEventLatencies.count) * 0.95)) - 1
                )
            ]
        }
        return AppleQualificationReport(
            modelFingerprint: fingerprint,
            observationCount: eligibleRecords.count,
            gateDecisionCount: gateDecisions.count,
            meaningfulObservationCount: gateDecisions.filter(\.cloudMeaningful).count,
            criticalCaseCount: eligibleRecords.filter(\.isCriticalCase).count,
            criticalBypassViolationCount: eligibleRecords.filter {
                $0.isCriticalCase && ($0.generationAttempted || $0.verdict != nil)
            }.count,
            falseRejectionCount: gateDecisions.filter(\.falseRejection).count,
            criticalFalseRejectionCount: gateDecisions.filter {
                $0.isCriticalCase && $0.falseRejection
            }.count,
            structuredGenerationCount: generations.count,
            validStructuredGenerationCount: generations.filter(\.structuredOutputValid).count,
            cacheHitCount: eligibleRecords.filter { $0.generationAttempted && $0.fromCache }.count,
            warmLatencyP95Milliseconds: p95,
            localEventAttemptCount: localEventAttempts.count,
            validLocalEventGenerationCount: localEventAttempts.filter {
                $0.localEventOutcome == .generated && !$0.localEventSafetyViolation
            }.count,
            localEventCloudCompatibleCount: localEventAttempts.filter {
                $0.localEventOutcome == .generated
                    && $0.localEventCloudCompatible == true
                    && !$0.localEventSafetyViolation
            }.count,
            localEventCriticalMismatchCount: localEventAttempts.filter(\.localEventCriticalMismatch).count,
            localEventSafetyViolationCount: localEventAttempts.filter(\.localEventSafetyViolation).count,
            localEventLatencyP95Milliseconds: localEventP95
        )
    }
}
