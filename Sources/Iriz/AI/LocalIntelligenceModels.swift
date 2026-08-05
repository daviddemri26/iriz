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
        guard !DeterministicLocalGatePolicy.containsHighRiskSignal(in: combinedText) else {
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
}

enum LocalEventDraftValidationError: Error, Equatable, Sendable {
    case emptyTitle
    case emptySummary
    case titleTooLong
    case summaryTooLong
    case highRiskContent
}

struct AppleModelFingerprint: Codable, Hashable, Sendable {
    let modelFamily: String
    let operatingSystemMajor: Int
    let operatingSystemMinor: Int
    let contextWindowTokens: Int
    let localeIdentifier: String
    let promptVersion: String
    let schemaVersion: String

    init(
        modelFamily: String = "system-language-model.default",
        operatingSystemMajor: Int,
        operatingSystemMinor: Int,
        contextWindowTokens: Int = 4_096,
        localeIdentifier: String,
        promptVersion: String,
        schemaVersion: String
    ) {
        self.modelFamily = modelFamily
        self.operatingSystemMajor = operatingSystemMajor
        self.operatingSystemMinor = operatingSystemMinor
        self.contextWindowTokens = contextWindowTokens
        self.localeIdentifier = localeIdentifier
        self.promptVersion = promptVersion
        self.schemaVersion = schemaVersion
    }

    var stableIdentifier: String {
        [
            modelFamily,
            "macOS-\(operatingSystemMajor).\(operatingSystemMinor)",
            "context-\(contextWindowTokens)",
            localeIdentifier,
            promptVersion,
            schemaVersion
        ].joined(separator: ":")
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

enum LocalGateRoute: Equatable, Sendable {
    case suppressCloud
    case useCloud
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

    static func cloud(
        reason: LocalGateDecisionReason,
        contentFingerprint: String,
        verdict: LocalGateVerdict? = nil,
        modelFingerprint: AppleModelFingerprint? = nil,
        fromCache: Bool = false
    ) -> LocalGateDecision {
        LocalGateDecision(
            route: .useCloud,
            verdict: verdict,
            reason: reason,
            contentFingerprint: contentFingerprint,
            modelFingerprint: modelFingerprint,
            fromCache: fromCache
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
