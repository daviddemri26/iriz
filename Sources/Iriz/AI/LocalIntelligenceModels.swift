import Foundation
import FoundationModels

@available(macOS 26.0, *)
@Generable(description: "A conservative decision about whether an observation needs cloud analysis.")
enum LocalGateVerdict: String, Codable, CaseIterable, Equatable, Sendable {
    case clearlyEmpty
    case uncertain
    case meaningful
}

@available(macOS 26.0, *)
@Generable(description: "The only event categories that may be created without cloud review.")
enum LocalEventDraftKind: String, Codable, CaseIterable, Equatable, Sendable {
    case context
    case research
    case document
    case note

    var eventKind: EventKind {
        switch self {
        case .context: .context
        case .research: .research
        case .document: .document
        case .note: .note
        }
    }
}

@available(macOS 26.0, *)
@Generable(description: "A low-risk observed event. It must not describe a commitment, deadline, transaction, decision, meeting, or completion.")
struct LocalEventDraft: Equatable, Sendable {
    let kind: LocalEventDraftKind

    @Guide(description: "A factual title of at most 80 characters.")
    let title: String

    @Guide(description: "A factual summary of at most 240 characters.")
    let summary: String

    init(kind: LocalEventDraftKind, title: String, summary: String) {
        self.kind = kind
        self.title = title
        self.summary = summary
    }

    func validated() throws -> LocalEventDraft {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedTitle.isEmpty else {
            throw LocalEventDraftValidationError.emptyTitle
        }
        guard !normalizedSummary.isEmpty else {
            throw LocalEventDraftValidationError.emptySummary
        }
        guard normalizedTitle.count <= 80 else {
            throw LocalEventDraftValidationError.titleTooLong
        }
        guard normalizedSummary.count <= 240 else {
            throw LocalEventDraftValidationError.summaryTooLong
        }

        let combinedText = "\(normalizedTitle)\n\(normalizedSummary)"
        guard !DeterministicLocalGatePolicy.containsHighRiskSignal(in: combinedText),
              !Self.containsProhibitedDraftClaim(in: combinedText) else {
            throw LocalEventDraftValidationError.highRiskContent
        }

        return LocalEventDraft(
            kind: kind,
            title: normalizedTitle,
            summary: normalizedSummary
        )
    }

    func makeActivityEvent(
        from observation: Observation,
        languageTag: String,
        confidence: Double = 0.60
    ) throws -> ActivityEvent {
        let draft = try validated()
        let evidence = EvidenceReference(
            observationID: observation.id,
            source: observation.source,
            capturedAt: observation.capturedAt,
            expiresAt: observation.expiresAt,
            mediaIdentifier: observation.mediaIdentifier,
            excerpt: String(observation.text.prefix(500))
        )

        return ActivityEvent(
            id: observation.id,
            startedAt: observation.capturedAt,
            endedAt: observation.capturedAt,
            kind: draft.kind.eventKind,
            status: .observed,
            importance: .normal,
            title: draft.title,
            summary: draft.summary,
            languageTag: languageTag,
            urls: [observation.url].compactMap { $0 },
            sourceApplications: [observation.applicationName].compactMap { $0 },
            confidence: min(max(confidence, 0), 0.70),
            evidence: [evidence]
        )
    }

    /// Local drafts are observations only. This deliberately rejects language that
    /// could turn a neutral note into an Action, meeting, promise, or completion even
    /// when the broader gate vocabulary does not happen to match it.
    private static func containsProhibitedDraftClaim(in text: String) -> Bool {
        let normalized = DeterministicLocalGatePolicy.normalized(text)
        let patterns = [
            #"\b(?:action|action item|task|todo|to-do|next step|follow-up|follow up|reminder)\b"#,
            #"\b(?:meeting|call|appointment|reunion|rendez-vous)\b"#,
            #"\b(?:promise|promised|commitment|committed|intend|intends|plan to|plans to)\b"#,
            #"\b(?:must|should|need to|needs to|will|shall)\b"#,
            #"\b(?:deadline|due|overdue|completed|complete|finished|done|finalized|closed)\b"#,
            #"\b(?:tache|a faire|prochaine etape|rappel|promesse|engagement)\b"#,
            #"\b(?:doit|devra|prevoit de|a l'intention de|terminee|termine|finalisee|finalise)\b"#
        ]
        return patterns.contains { normalized.range(of: $0, options: .regularExpression) != nil }
    }
}

enum LocalEventDraftValidationError: Error, Equatable, Sendable {
    case emptyTitle
    case emptySummary
    case titleTooLong
    case summaryTooLong
    case highRiskContent
}

/// Qualification requires semantic agreement, not merely the same safe
/// envelope. This prevents a fluent but unrelated local title/summary from
/// being promoted simply because both outputs are low-risk observations.
@available(macOS 26.0, *)
enum LocalEventSemanticAgreement {
    static func isCompatible(_ draft: LocalEventDraft, with cloudEvent: ActivityEvent) -> Bool {
        guard draft.kind.eventKind == cloudEvent.kind else { return false }
        let localTokens = contentTokens(in: "\(draft.title) \(draft.summary)")
        let cloudTokens = contentTokens(in: "\(cloudEvent.title) \(cloudEvent.summary)")
        guard localTokens.count >= 2, cloudTokens.count >= 2 else { return false }
        let intersection = localTokens.intersection(cloudTokens)
        let localCoverage = Double(intersection.count) / Double(localTokens.count)
        let cloudCoverage = Double(intersection.count) / Double(cloudTokens.count)

        let localTitleTokens = contentTokens(in: draft.title)
        let titleAgrees = localTitleTokens.isEmpty
            || !localTitleTokens.intersection(cloudTokens).isEmpty
        return titleAgrees && localCoverage >= 0.45 && cloudCoverage >= 0.25
    }

    private static func contentTokens(in text: String) -> Set<String> {
        let stopwords: Set<String> = [
            "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "in", "is",
            "it", "of", "on", "or", "the", "this", "to", "was", "with",
            "au", "aux", "avec", "ce", "ces", "dans", "de", "des", "du", "en", "est",
            "et", "la", "le", "les", "ou", "par", "pour", "sur", "un", "une"
        ]
        return Set(
            DeterministicLocalGatePolicy.normalized(text)
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count >= 3 && !stopwords.contains($0) }
        )
    }
}

struct AppleModelFingerprint: Codable, Hashable, Sendable {
    let modelFamily: String
    let operatingSystemMajor: Int
    let operatingSystemMinor: Int
    let contextWindowTokens: Int
    let localeIdentifier: String
    let promptVersion: String
    let schemaVersion: String
    let localEventPromptVersion: String
    let localEventSchemaVersion: String

    init(
        modelFamily: String = "system-language-model.default",
        operatingSystemMajor: Int,
        operatingSystemMinor: Int,
        contextWindowTokens: Int = 4_096,
        localeIdentifier: String,
        promptVersion: String,
        schemaVersion: String,
        localEventPromptVersion: String = "local-event-v1",
        localEventSchemaVersion: String = "local-event-draft-v1"
    ) {
        self.modelFamily = modelFamily
        self.operatingSystemMajor = operatingSystemMajor
        self.operatingSystemMinor = operatingSystemMinor
        self.contextWindowTokens = contextWindowTokens
        self.localeIdentifier = localeIdentifier
        self.promptVersion = promptVersion
        self.schemaVersion = schemaVersion
        self.localEventPromptVersion = localEventPromptVersion
        self.localEventSchemaVersion = localEventSchemaVersion
    }

    var stableIdentifier: String {
        [
            modelFamily,
            "macOS-\(operatingSystemMajor).\(operatingSystemMinor)",
            "context-\(contextWindowTokens)",
            localeIdentifier,
            promptVersion,
            schemaVersion,
            localEventPromptVersion,
            localEventSchemaVersion
        ].joined(separator: ":")
    }

    private enum CodingKeys: String, CodingKey {
        case modelFamily
        case operatingSystemMajor
        case operatingSystemMinor
        case contextWindowTokens
        case localeIdentifier
        case promptVersion
        case schemaVersion
        case localEventPromptVersion
        case localEventSchemaVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelFamily = try container.decode(String.self, forKey: .modelFamily)
        operatingSystemMajor = try container.decode(Int.self, forKey: .operatingSystemMajor)
        operatingSystemMinor = try container.decode(Int.self, forKey: .operatingSystemMinor)
        contextWindowTokens = try container.decode(Int.self, forKey: .contextWindowTokens)
        localeIdentifier = try container.decode(String.self, forKey: .localeIdentifier)
        promptVersion = try container.decode(String.self, forKey: .promptVersion)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        // A legacy fingerprint never qualified local event generation. Decode
        // it to an incompatible sentinel so it cannot silently gain authority.
        localEventPromptVersion = try container.decodeIfPresent(
            String.self,
            forKey: .localEventPromptVersion
        ) ?? "legacy-unversioned"
        localEventSchemaVersion = try container.decodeIfPresent(
            String.self,
            forKey: .localEventSchemaVersion
        ) ?? "legacy-unversioned"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(modelFamily, forKey: .modelFamily)
        try container.encode(operatingSystemMajor, forKey: .operatingSystemMajor)
        try container.encode(operatingSystemMinor, forKey: .operatingSystemMinor)
        try container.encode(contextWindowTokens, forKey: .contextWindowTokens)
        try container.encode(localeIdentifier, forKey: .localeIdentifier)
        try container.encode(promptVersion, forKey: .promptVersion)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(localEventPromptVersion, forKey: .localEventPromptVersion)
        try container.encode(localEventSchemaVersion, forKey: .localEventSchemaVersion)
    }
}

struct AppleQualificationProfile: Codable, Equatable, Sendable {
    let fingerprint: AppleModelFingerprint
    let gateEnabled: Bool
    let localEventDraftEnabled: Bool
    let qualifiedAt: Date

    init(
        fingerprint: AppleModelFingerprint,
        gateEnabled: Bool,
        localEventDraftEnabled: Bool = false,
        qualifiedAt: Date
    ) {
        self.fingerprint = fingerprint
        self.gateEnabled = gateEnabled
        self.localEventDraftEnabled = localEventDraftEnabled
        self.qualifiedAt = qualifiedAt
    }
}

struct AppleQualificationRegistry: Sendable {
    private let profilesByFingerprint: [AppleModelFingerprint: AppleQualificationProfile]

    init(profiles: [AppleQualificationProfile] = []) {
        self.profilesByFingerprint = Dictionary(
            profiles.map { ($0.fingerprint, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    func profile(for fingerprint: AppleModelFingerprint) -> AppleQualificationProfile? {
        profilesByFingerprint[fingerprint]
    }

    static let production = AppleQualificationRegistry()
}

enum LocalModelAvailability: Equatable, Sendable {
    case available
    case unsupportedOperatingSystem
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unsupportedLocale
    case unknown
}

enum LocalIntelligenceFallbackReason: Equatable, Sendable {
    case disabled
    case shadowMode
    case unqualifiedModel
    case unsupportedOperatingSystem
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unsupportedLocale
    case unavailable
}

enum LocalIntelligenceStatus: Equatable, Sendable {
    case active(AppleModelFingerprint)
    case fallback(LocalIntelligenceFallbackReason)
}

enum LocalGateMode: Equatable, Sendable {
    case disabled
    case shadow
    case adaptive
}

enum LocalEventDraftPolicy: Equatable, Sendable {
    case disabled
    case shadowOnly
    case routing
}

enum LocalGateRoute: Equatable, Sendable {
    case suppressCloud
    case useCloud
}

@available(macOS 26.0, *)
enum LocalEventDraftAttemptOutcome: String, Codable, Equatable, Sendable {
    case notAttempted
    case unqualifiedModel
    case generated
    case rejectedOutput
    case generationFailed
}

/// A separate, typed qualification result for the local-event capability. Shadow
/// mode can retain this alongside the cloud interpretation without ever changing
/// routing, while Adaptive may consume only a validated `generated` draft.
@available(macOS 26.0, *)
struct LocalEventDraftAttempt: Equatable, Sendable {
    let outcome: LocalEventDraftAttemptOutcome
    let draft: LocalEventDraft?
    let latencyMilliseconds: Int?

    static let notAttempted = LocalEventDraftAttempt(
        outcome: .notAttempted,
        draft: nil,
        latencyMilliseconds: nil
    )

    static let unqualified = LocalEventDraftAttempt(
        outcome: .unqualifiedModel,
        draft: nil,
        latencyMilliseconds: nil
    )
}

enum LocalGateDecisionReason: Equatable, Sendable {
    case gateDisabled
    case shadowMode
    case meeting
    case manualNote
    case retry
    case visualContextRequired
    case insufficientText
    case highRiskSignal
    case unavailable(LocalModelAvailability)
    case unqualifiedModel
    case clearlyEmpty
    case uncertain
    case meaningful
    case generationFailed
}

@available(macOS 26.0, *)
struct LocalGateDecision: Equatable, Sendable {
    let route: LocalGateRoute
    let verdict: LocalGateVerdict?
    let reason: LocalGateDecisionReason
    let contentFingerprint: String
    let modelFingerprint: AppleModelFingerprint?
    let fromCache: Bool
    /// Time spent generating only the gate verdict. This deliberately excludes
    /// the separately-qualified local-event draft so gate p95 remains meaningful.
    let classificationLatencyMilliseconds: Int?
    let localEventDraftAttempt: LocalEventDraftAttempt

    static func cloud(
        reason: LocalGateDecisionReason,
        contentFingerprint: String,
        verdict: LocalGateVerdict? = nil,
        modelFingerprint: AppleModelFingerprint? = nil,
        fromCache: Bool = false,
        classificationLatencyMilliseconds: Int? = nil,
        localEventDraftAttempt: LocalEventDraftAttempt = .notAttempted
    ) -> LocalGateDecision {
        LocalGateDecision(
            route: .useCloud,
            verdict: verdict,
            reason: reason,
            contentFingerprint: contentFingerprint,
            modelFingerprint: modelFingerprint,
            fromCache: fromCache,
            classificationLatencyMilliseconds: classificationLatencyMilliseconds,
            localEventDraftAttempt: localEventDraftAttempt
        )
    }
}

struct LocalGateInput: Equatable, Sendable {
    let source: ObservationSource
    let applicationName: String?
    let windowTitle: String?
    let host: String?
    let text: String
    let languageTag: String
    let isMeeting: Bool
    let isRetry: Bool
    let requiresVisualContext: Bool
    let suppliedContentFingerprint: String?

    init(
        source: ObservationSource,
        applicationName: String? = nil,
        windowTitle: String? = nil,
        host: String? = nil,
        text: String,
        languageTag: String,
        isMeeting: Bool = false,
        isRetry: Bool = false,
        requiresVisualContext: Bool = false,
        suppliedContentFingerprint: String? = nil
    ) {
        self.source = source
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.host = host
        self.text = text
        self.languageTag = languageTag
        self.isMeeting = isMeeting
        self.isRetry = isRetry
        self.requiresVisualContext = requiresVisualContext
        self.suppliedContentFingerprint = suppliedContentFingerprint
    }

    init(
        observation: Observation,
        languageTag: String,
        isRetry: Bool = false,
        requiresVisualContext: Bool = false
    ) {
        self.init(
            source: observation.source,
            applicationName: observation.applicationName,
            windowTitle: observation.windowTitle,
            host: observation.url?.host(),
            text: observation.text,
            languageTag: languageTag,
            isMeeting: observation.isMeeting,
            isRetry: isRetry,
            requiresVisualContext: requiresVisualContext,
            suppliedContentFingerprint: observation.contentFingerprint
        )
    }
}
