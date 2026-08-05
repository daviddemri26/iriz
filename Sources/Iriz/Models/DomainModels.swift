import Foundation

enum ObservationSource: String, Codable, CaseIterable, Sendable {
    case screen
    case ambientAudio
    case meetingMicrophone
    case meetingSystemAudio
    case manualNote
}

enum EventKind: String, Codable, CaseIterable, Sendable {
    case application
    case purchase
    case appointment
    case communication
    case document
    case meeting
    case research
    case decision
    case task
    case note
    case context
    case other

    var displayName: String {
        switch self {
        case .application: "Application"
        case .purchase: "Purchase"
        case .appointment: "Appointment"
        case .communication: "Communication"
        case .document: "Document"
        case .meeting: "Meeting"
        case .research: "Research"
        case .decision: "Decision"
        case .task: "Task"
        case .note: "Note"
        case .context: "Context"
        case .other: "Other"
        }
    }

    var symbolName: String {
        switch self {
        case .application: "paperplane.fill"
        case .purchase: "bag.fill"
        case .appointment: "calendar.badge.clock"
        case .communication: "bubble.left.and.bubble.right.fill"
        case .document: "doc.text.fill"
        case .meeting: "person.2.fill"
        case .research: "magnifyingglass"
        case .decision: "signpost.right.fill"
        case .task: "checkmark.circle.fill"
        case .note: "note.text"
        case .context: "circle.dotted"
        case .other: "sparkles"
        }
    }
}

enum EventStatus: String, Codable, CaseIterable, Sendable {
    case observed
    case inProgress
    case completed
    case uncertain

    var displayName: String {
        switch self {
        case .observed: "Observed"
        case .inProgress: "In progress"
        case .completed: "Completed"
        case .uncertain: "Uncertain"
        }
    }
}

enum EventImportance: Int, Codable, CaseIterable, Comparable, Sendable {
    case background = 0
    case normal = 1
    case important = 2
    case critical = 3

    static func < (lhs: EventImportance, rhs: EventImportance) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum CommitmentState: String, Codable, CaseIterable, Sendable {
    case needsAttention
    case completionSuggested
    case later
    case waiting
    case maybe
    case completed
    case dismissed

    var displayName: String {
        switch self {
        case .needsAttention: "Needs attention"
        case .completionSuggested: "Suggested done"
        case .later: "Later"
        case .waiting: "Waiting"
        case .maybe: "Maybe"
        case .completed: "Completed"
        case .dismissed: "Dismissed"
        }
    }
}

enum FollowUpLifecycle: String, Codable, CaseIterable, Sendable {
    case active
    case snoozed
    case completed
    case dismissed

    static func migrate(from state: CommitmentState, reviewAt: Date?, now: Date = Date()) -> FollowUpLifecycle {
        switch state {
        case .completed: .completed
        case .dismissed: .dismissed
        case .waiting where reviewAt.map { $0 > now } == true: .snoozed
        case .later where reviewAt.map { $0 > now } == true: .snoozed
        case .needsAttention, .completionSuggested, .later, .waiting, .maybe: .active
        }
    }

    var legacyState: CommitmentState {
        switch self {
        case .active: .needsAttention
        case .snoozed: .later
        case .completed: .completed
        case .dismissed: .dismissed
        }
    }
}

enum FollowUpDetailLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case outcome
    case milestone
    case standard
    case detailed
    case micro

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .outcome: "Outcome"
        case .milestone: "Milestone"
        case .standard: "Standard"
        case .detailed: "Detailed"
        case .micro: "Micro"
        }
    }

    var description: String {
        switch self {
        case .outcome: "Keep only the final result that needs to be achieved."
        case .milestone: "Keep major checkpoints without breaking them into routine steps."
        case .standard: "Keep practical next actions at a useful everyday level."
        case .detailed: "Break work into smaller actionable steps with supporting context."
        case .micro: "Capture every concrete action, including short operational steps."
        }
    }
}

enum FollowUpArea: String, Codable, CaseIterable, Identifiable, Sendable {
    case work
    case personal
    case uncategorized

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .work: "Work"
        case .personal: "Personal"
        case .uncategorized: "Uncategorized"
        }
    }

    static func inferred(from label: String?) -> FollowUpArea {
        let folded = label?
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased() ?? ""
        if ["work", "travail", "business", "professional", "job"].contains(where: folded.contains) { return .work }
        if [
            "personal", "personnel", "family", "famille", "home", "travel", "voyage",
            "vacation", "holiday", "trip", "kids", "children", "enfants"
        ].contains(where: folded.contains) { return .personal }
        return .uncategorized
    }
}

enum FollowUpColorToken: String, Codable, CaseIterable, Identifiable, Sendable {
    case violet
    case indigo
    case blue
    case teal
    case mint
    case green
    case yellow
    case orange
    case coral
    case pink
    case plum
    case brown

    var id: String { rawValue }

    static func stable(for value: String) -> FollowUpColorToken {
        let total = value.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fff_ffff }
        let values = allCases
        return values[total % values.count]
    }
}

/// A user-manageable classification for subjects. `area` remains the small,
/// stable category used internally by the extraction engine, while visible
/// types can be named Client, Project, Family, Administration, and so on.
struct FollowUpType: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var area: FollowUpArea
    var color: FollowUpColorToken
    var systemImage: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String? = nil,
        name: String,
        area: FollowUpArea = .uncategorized,
        color: FollowUpColorToken? = nil,
        systemImage: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Uncategorized"
            : name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id ?? "type-\(UUID().uuidString.lowercased())"
        self.name = cleanName
        self.area = area
        self.color = color ?? .stable(for: cleanName)
        self.systemImage = systemImage ?? Self.defaultSystemImage(for: area)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var isBuiltIn: Bool { Self.builtInIDs.contains(id) }

    static let workID = "work"
    static let personalID = "personal"
    static let uncategorizedID = "uncategorized"
    static let builtInIDs: Set<String> = [workID, personalID, uncategorizedID]

    static var defaults: [FollowUpType] {
        [
            FollowUpType(id: workID, name: "Work", area: .work, color: .blue, systemImage: "briefcase.fill"),
            FollowUpType(id: personalID, name: "Personal", area: .personal, color: .pink, systemImage: "person.fill"),
            FollowUpType(id: uncategorizedID, name: "Uncategorized", area: .uncategorized, color: .violet, systemImage: "square.grid.2x2")
        ]
    }

    static func defaultID(for area: FollowUpArea) -> String { area.rawValue }

    static func defaultSystemImage(for area: FollowUpArea) -> String {
        switch area {
        case .work: "briefcase.fill"
        case .personal: "person.fill"
        case .uncategorized: "square.grid.2x2"
        }
    }
}

enum FollowUpOrigin: String, Codable, Sendable {
    case iriz
    case manual
}

enum FollowUpCompletionActor: String, Codable, CaseIterable, Sendable {
    case user
    case iriz

    var displayName: String {
        switch self {
        case .user: "Completed by you"
        case .iriz: "Completed by iriz"
        }
    }
}

enum FollowUpDueSource: String, Codable, Sendable {
    case explicitEvidence
    case inferredByIriz
    case user
}

enum FollowUpEvidenceStrength: String, Codable, Sendable {
    case weak
    case strong
    case explicit
}

struct FollowUpCompletionEvidence: Codable, Hashable, Sendable {
    var eventID: UUID
    var summary: String
    var confidence: Double
    var strength: FollowUpEvidenceStrength
    var capturedAt: Date

    init(
        eventID: UUID,
        summary: String,
        confidence: Double,
        strength: FollowUpEvidenceStrength,
        capturedAt: Date
    ) {
        self.eventID = eventID
        self.summary = summary
        self.confidence = min(max(confidence, 0), 1)
        self.strength = strength
        self.capturedAt = capturedAt
    }
}

enum FollowUpEditableField: String, Codable, Hashable, Sendable {
    case action
    case summary
    case details
    case subject
    case priority
    case dueDate
    case owner
}

enum FollowUpHistoryKind: String, Codable, Sendable {
    case created
    case edited
    case prioritized
    case snoozed
    case resurfaced
    case completed
    case reopened
    case dismissed
    case restored
    case evidence
    case merged
    case exported
}

enum FollowUpHistoryActor: String, Codable, Sendable {
    case user
    case iriz
    case system
}

struct FollowUpHistoryEntry: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var kind: FollowUpHistoryKind
    var actor: FollowUpHistoryActor
    var summary: String
    var occurredAt: Date
    var eventID: UUID?

    init(
        id: UUID = UUID(),
        kind: FollowUpHistoryKind,
        actor: FollowUpHistoryActor,
        summary: String,
        occurredAt: Date = Date(),
        eventID: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.actor = actor
        self.summary = summary
        self.occurredAt = occurredAt
        self.eventID = eventID
    }
}

struct FollowUpSubject: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var area: FollowUpArea
    var typeID: String?
    var color: FollowUpColorToken
    var aliases: Set<String>
    var priorityBias: Double
    var correctionCount: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String? = nil,
        name: String,
        area: FollowUpArea = .uncategorized,
        typeID: String? = nil,
        color: FollowUpColorToken? = nil,
        aliases: Set<String> = [],
        priorityBias: Double = 0,
        correctionCount: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Uncategorized" : name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id ?? Self.identifier(for: cleanName)
        self.name = cleanName
        self.area = area
        self.typeID = typeID ?? FollowUpType.defaultID(for: area)
        self.color = color ?? .stable(for: cleanName)
        self.aliases = aliases
        self.priorityBias = min(max(priorityBias, -3), 3)
        self.correctionCount = max(0, correctionCount)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static func identifier(for value: String) -> String {
        let folded = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        let words = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return words.isEmpty ? "uncategorized" : words.joined(separator: "-")
    }

    mutating func learn(aiScore: Int, userScore: Int) {
        let delta = Double(min(max(userScore, 0), 10) - min(max(aiScore, 0), 10))
        priorityBias = min(max(0.75 * priorityBias + 0.25 * delta, -3), 3)
        correctionCount += 1
        updatedAt = Date()
    }
}

struct EvidenceReference: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var observationID: UUID
    var source: ObservationSource
    var capturedAt: Date
    var expiresAt: Date?
    var mediaIdentifier: String?
    var excerpt: String?

    init(
        id: UUID = UUID(),
        observationID: UUID,
        source: ObservationSource,
        capturedAt: Date,
        expiresAt: Date? = nil,
        mediaIdentifier: String? = nil,
        excerpt: String? = nil
    ) {
        self.id = id
        self.observationID = observationID
        self.source = source
        self.capturedAt = capturedAt
        self.expiresAt = expiresAt
        self.mediaIdentifier = mediaIdentifier
        self.excerpt = excerpt
    }
}

struct Observation: Codable, Identifiable, Sendable {
    var id: UUID
    var source: ObservationSource
    var capturedAt: Date
    var expiresAt: Date
    var applicationName: String?
    var bundleIdentifier: String?
    var windowTitle: String?
    var url: URL?
    var text: String
    var mediaIdentifier: String?
    var contentFingerprint: String?
    var isMeeting: Bool
    var processedAt: Date?

    init(
        id: UUID = UUID(),
        source: ObservationSource,
        capturedAt: Date = Date(),
        expiresAt: Date = Date().addingTimeInterval(24 * 60 * 60),
        applicationName: String? = nil,
        bundleIdentifier: String? = nil,
        windowTitle: String? = nil,
        url: URL? = nil,
        text: String = "",
        mediaIdentifier: String? = nil,
        contentFingerprint: String? = nil,
        isMeeting: Bool = false,
        processedAt: Date? = nil
    ) {
        self.id = id
        self.source = source
        self.capturedAt = capturedAt
        self.expiresAt = expiresAt
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.url = url
        self.text = text
        self.mediaIdentifier = mediaIdentifier
        self.contentFingerprint = contentFingerprint
        self.isMeeting = isMeeting
        self.processedAt = processedAt
    }
}

struct ActivityEvent: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date
    var kind: EventKind
    var status: EventStatus
    var importance: EventImportance
    var title: String
    var summary: String
    var details: String
    var languageTag: String
    var entities: [String]
    var urls: [URL]
    var sourceApplications: [String]
    var confidence: Double
    var evidence: [EvidenceReference]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date,
        kind: EventKind,
        status: EventStatus,
        importance: EventImportance,
        title: String,
        summary: String,
        details: String = "",
        languageTag: String = "en-US",
        entities: [String] = [],
        urls: [URL] = [],
        sourceApplications: [String] = [],
        confidence: Double,
        evidence: [EvidenceReference] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.kind = kind
        self.status = status
        self.importance = importance
        self.title = title
        self.summary = summary
        self.details = details
        self.languageTag = languageTag
        self.entities = entities
        self.urls = urls
        self.sourceApplications = sourceApplications
        self.confidence = min(max(confidence, 0), 1)
        self.evidence = evidence
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var searchableText: String {
        ([title, summary, details] + entities + urls.map(\.absoluteString) + sourceApplications)
            .joined(separator: " ")
    }
}

struct Commitment: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var eventID: UUID
    var owner: String
    var action: String
    var rationale: String
    var explicitDueAt: Date?
    var suggestedReviewAt: Date?
    var contextLabel: String?
    var isPriority: Bool
    var confidence: Double
    var state: CommitmentState
    var linkedEventIDs: [UUID]
    var createdAt: Date
    var updatedAt: Date
    var summary: String
    var details: String
    var lifecycle: FollowUpLifecycle
    var subjectID: String?
    var area: FollowUpArea
    var origin: FollowUpOrigin
    var detailLevelAtCreation: FollowUpDetailLevel
    var aiPriorityScore: Int
    var displayPriorityScore: Int
    var userPriorityScore: Int?
    var priorityReason: String
    var surfacedAt: Date
    var snoozedUntil: Date?
    var completedAt: Date?
    var dismissedAt: Date?
    var completionActor: FollowUpCompletionActor?
    var completionEvidence: FollowUpCompletionEvidence?
    var dueSource: FollowUpDueSource?
    var dueConfidence: Double?
    var evidenceHint: String?
    var manuallyEditedFields: Set<FollowUpEditableField>
    var history: [FollowUpHistoryEntry]

    init(
        id: UUID = UUID(),
        eventID: UUID,
        owner: String,
        action: String,
        rationale: String = "",
        explicitDueAt: Date? = nil,
        suggestedReviewAt: Date? = nil,
        contextLabel: String? = nil,
        isPriority: Bool = false,
        confidence: Double,
        state: CommitmentState,
        linkedEventIDs: [UUID] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        summary: String = "",
        details: String = "",
        lifecycle: FollowUpLifecycle? = nil,
        subjectID: String? = nil,
        area: FollowUpArea? = nil,
        origin: FollowUpOrigin = .iriz,
        detailLevelAtCreation: FollowUpDetailLevel = .standard,
        aiPriorityScore: Int? = nil,
        displayPriorityScore: Int? = nil,
        userPriorityScore: Int? = nil,
        priorityReason: String = "",
        surfacedAt: Date? = nil,
        snoozedUntil: Date? = nil,
        completedAt: Date? = nil,
        dismissedAt: Date? = nil,
        completionActor: FollowUpCompletionActor? = nil,
        completionEvidence: FollowUpCompletionEvidence? = nil,
        dueSource: FollowUpDueSource? = nil,
        dueConfidence: Double? = nil,
        evidenceHint: String? = nil,
        manuallyEditedFields: Set<FollowUpEditableField> = [],
        history: [FollowUpHistoryEntry] = []
    ) {
        self.id = id
        self.eventID = eventID
        self.owner = owner
        self.action = action
        self.rationale = rationale
        self.explicitDueAt = explicitDueAt
        self.suggestedReviewAt = suggestedReviewAt
        self.contextLabel = contextLabel
        self.isPriority = isPriority
        self.confidence = min(max(confidence, 0), 1)
        self.state = state
        self.linkedEventIDs = linkedEventIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.summary = summary
        self.details = details
        let reviewAt = explicitDueAt ?? suggestedReviewAt
        self.lifecycle = lifecycle ?? .migrate(from: state, reviewAt: reviewAt)
        self.subjectID = subjectID ?? contextLabel.map(FollowUpSubject.identifier(for:))
        self.area = area ?? .inferred(from: contextLabel)
        self.origin = origin
        self.detailLevelAtCreation = detailLevelAtCreation
        self.aiPriorityScore = min(max(aiPriorityScore ?? Self.legacyPriority(for: state, isPriority: isPriority, hasDueDate: explicitDueAt != nil), 0), 10)
        self.displayPriorityScore = min(max(displayPriorityScore ?? self.aiPriorityScore, 0), 10)
        self.userPriorityScore = userPriorityScore.map { min(max($0, 0), 10) }
        self.priorityReason = priorityReason
        self.surfacedAt = surfacedAt ?? createdAt
        self.snoozedUntil = snoozedUntil ?? (self.lifecycle == .snoozed ? reviewAt : nil)
        self.completedAt = completedAt ?? (self.lifecycle == .completed ? updatedAt : nil)
        self.dismissedAt = dismissedAt ?? (self.lifecycle == .dismissed ? updatedAt : nil)
        self.completionActor = completionActor ?? (self.lifecycle == .completed ? (rationale.contains("Automatically completed") ? .iriz : .user) : nil)
        self.completionEvidence = completionEvidence
        self.dueSource = dueSource ?? (explicitDueAt == nil ? nil : .explicitEvidence)
        self.dueConfidence = dueConfidence.map { min(max($0, 0), 1) }
        self.evidenceHint = evidenceHint
        self.manuallyEditedFields = manuallyEditedFields
        self.history = history
    }

    var priorityScore: Int { min(max(userPriorityScore ?? displayPriorityScore, 0), 10) }
    /// A deadline is only a date explicitly entered by the user or observed in
    /// source evidence. Suggested review dates are retained for decoding older
    /// development data, but are never presented as deadlines.
    var dueAt: Date? { explicitDueAt }

    mutating func setLifecycle(_ value: FollowUpLifecycle, actor: FollowUpHistoryActor, now: Date = Date()) {
        lifecycle = value
        state = value.legacyState
        updatedAt = now
        switch value {
        case .active:
            snoozedUntil = nil
            completedAt = nil
            dismissedAt = nil
        case .snoozed:
            completedAt = nil
            dismissedAt = nil
        case .completed:
            completedAt = now
            snoozedUntil = nil
            dismissedAt = nil
        case .dismissed:
            dismissedAt = now
            snoozedUntil = nil
            completedAt = nil
        }
        let kind: FollowUpHistoryKind = switch value {
        case .active: actor == .user ? .reopened : .resurfaced
        case .snoozed: .snoozed
        case .completed: .completed
        case .dismissed: .dismissed
        }
        history.append(FollowUpHistoryEntry(kind: kind, actor: actor, summary: value.rawValue.capitalized, occurredAt: now))
    }

    private static func legacyPriority(for state: CommitmentState, isPriority: Bool, hasDueDate: Bool) -> Int {
        if isPriority { return min(9 + (hasDueDate ? 1 : 0), 10) }
        let base: Int = switch state {
        case .completionSuggested: 8
        case .needsAttention: 7
        case .waiting: 5
        case .later: 4
        case .maybe: 2
        case .completed, .dismissed: 5
        }
        return min(base + (hasDueDate ? 1 : 0), 10)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case eventID
        case owner
        case action
        case rationale
        case explicitDueAt
        case suggestedReviewAt
        case contextLabel
        case isPriority
        case confidence
        case state
        case linkedEventIDs
        case createdAt
        case updatedAt
        case summary
        case details
        case lifecycle
        case subjectID
        case area
        case origin
        case detailLevelAtCreation
        case aiPriorityScore
        case displayPriorityScore
        case userPriorityScore
        case priorityReason
        case surfacedAt
        case snoozedUntil
        case completedAt
        case dismissedAt
        case completionActor
        case completionEvidence
        case dueSource
        case dueConfidence
        case evidenceHint
        case manuallyEditedFields
        case history
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        eventID = try values.decode(UUID.self, forKey: .eventID)
        owner = try values.decode(String.self, forKey: .owner)
        action = try values.decode(String.self, forKey: .action)
        rationale = try values.decodeIfPresent(String.self, forKey: .rationale) ?? ""
        explicitDueAt = try values.decodeIfPresent(Date.self, forKey: .explicitDueAt)
        suggestedReviewAt = try values.decodeIfPresent(Date.self, forKey: .suggestedReviewAt)
        contextLabel = try values.decodeIfPresent(String.self, forKey: .contextLabel)
        isPriority = try values.decodeIfPresent(Bool.self, forKey: .isPriority) ?? false
        confidence = min(max(try values.decode(Double.self, forKey: .confidence), 0), 1)
        state = try values.decode(CommitmentState.self, forKey: .state)
        linkedEventIDs = try values.decodeIfPresent([UUID].self, forKey: .linkedEventIDs) ?? []
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        summary = try values.decodeIfPresent(String.self, forKey: .summary) ?? ""
        details = try values.decodeIfPresent(String.self, forKey: .details) ?? ""
        lifecycle = try values.decodeIfPresent(FollowUpLifecycle.self, forKey: .lifecycle)
            ?? .migrate(from: state, reviewAt: explicitDueAt ?? suggestedReviewAt)
        subjectID = try values.decodeIfPresent(String.self, forKey: .subjectID)
            ?? contextLabel.map(FollowUpSubject.identifier(for:))
        area = try values.decodeIfPresent(FollowUpArea.self, forKey: .area) ?? .inferred(from: contextLabel)
        origin = try values.decodeIfPresent(FollowUpOrigin.self, forKey: .origin) ?? .iriz
        detailLevelAtCreation = try values.decodeIfPresent(FollowUpDetailLevel.self, forKey: .detailLevelAtCreation)
            ?? .standard
        aiPriorityScore = min(max(
            try values.decodeIfPresent(Int.self, forKey: .aiPriorityScore)
                ?? Self.legacyPriority(for: state, isPriority: isPriority, hasDueDate: explicitDueAt != nil),
            0
        ), 10)
        displayPriorityScore = min(max(
            try values.decodeIfPresent(Int.self, forKey: .displayPriorityScore) ?? aiPriorityScore,
            0
        ), 10)
        userPriorityScore = try values.decodeIfPresent(Int.self, forKey: .userPriorityScore).map { min(max($0, 0), 10) }
        priorityReason = try values.decodeIfPresent(String.self, forKey: .priorityReason) ?? ""
        surfacedAt = try values.decodeIfPresent(Date.self, forKey: .surfacedAt) ?? createdAt
        snoozedUntil = try values.decodeIfPresent(Date.self, forKey: .snoozedUntil)
            ?? (lifecycle == .snoozed ? explicitDueAt ?? suggestedReviewAt : nil)
        completedAt = try values.decodeIfPresent(Date.self, forKey: .completedAt) ?? (lifecycle == .completed ? updatedAt : nil)
        dismissedAt = try values.decodeIfPresent(Date.self, forKey: .dismissedAt) ?? (lifecycle == .dismissed ? updatedAt : nil)
        completionActor = try values.decodeIfPresent(FollowUpCompletionActor.self, forKey: .completionActor)
            ?? (lifecycle == .completed ? (rationale.contains("Automatically completed") ? .iriz : .user) : nil)
        completionEvidence = try values.decodeIfPresent(FollowUpCompletionEvidence.self, forKey: .completionEvidence)
        dueSource = try values.decodeIfPresent(FollowUpDueSource.self, forKey: .dueSource)
            ?? (explicitDueAt == nil ? nil : .explicitEvidence)
        dueConfidence = try values.decodeIfPresent(Double.self, forKey: .dueConfidence).map { min(max($0, 0), 1) }
        evidenceHint = try values.decodeIfPresent(String.self, forKey: .evidenceHint)
        manuallyEditedFields = try values.decodeIfPresent(Set<FollowUpEditableField>.self, forKey: .manuallyEditedFields) ?? []
        history = try values.decodeIfPresent([FollowUpHistoryEntry].self, forKey: .history) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(eventID, forKey: .eventID)
        try values.encode(owner, forKey: .owner)
        try values.encode(action, forKey: .action)
        try values.encode(rationale, forKey: .rationale)
        try values.encodeIfPresent(explicitDueAt, forKey: .explicitDueAt)
        try values.encodeIfPresent(suggestedReviewAt, forKey: .suggestedReviewAt)
        try values.encodeIfPresent(contextLabel, forKey: .contextLabel)
        try values.encode(isPriority, forKey: .isPriority)
        try values.encode(confidence, forKey: .confidence)
        try values.encode(state, forKey: .state)
        try values.encode(linkedEventIDs, forKey: .linkedEventIDs)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encode(summary, forKey: .summary)
        try values.encode(details, forKey: .details)
        try values.encode(lifecycle, forKey: .lifecycle)
        try values.encodeIfPresent(subjectID, forKey: .subjectID)
        try values.encode(area, forKey: .area)
        try values.encode(origin, forKey: .origin)
        try values.encode(detailLevelAtCreation, forKey: .detailLevelAtCreation)
        try values.encode(aiPriorityScore, forKey: .aiPriorityScore)
        try values.encode(displayPriorityScore, forKey: .displayPriorityScore)
        try values.encodeIfPresent(userPriorityScore, forKey: .userPriorityScore)
        try values.encode(priorityReason, forKey: .priorityReason)
        try values.encode(surfacedAt, forKey: .surfacedAt)
        try values.encodeIfPresent(snoozedUntil, forKey: .snoozedUntil)
        try values.encodeIfPresent(completedAt, forKey: .completedAt)
        try values.encodeIfPresent(dismissedAt, forKey: .dismissedAt)
        try values.encodeIfPresent(completionActor, forKey: .completionActor)
        try values.encodeIfPresent(completionEvidence, forKey: .completionEvidence)
        try values.encodeIfPresent(dueSource, forKey: .dueSource)
        try values.encodeIfPresent(dueConfidence, forKey: .dueConfidence)
        try values.encodeIfPresent(evidenceHint, forKey: .evidenceHint)
        try values.encode(manuallyEditedFields, forKey: .manuallyEditedFields)
        try values.encode(history, forKey: .history)
    }
}

struct PendingAnalysis: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case observation
        case transcript
    }

    var id: UUID
    var kind: Kind
    var observationID: UUID?
    var createdAt: Date
    var expiresAt: Date
    var attempts: Int
    var lastError: String?
}

struct AssistantCitation: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var eventID: UUID
    var title: String
    var timestamp: Date
    var url: URL?

    init(id: UUID = UUID(), eventID: UUID, title: String, timestamp: Date, url: URL? = nil) {
        self.id = id
        self.eventID = eventID
        self.title = title
        self.timestamp = timestamp
        self.url = url
    }
}

struct AssistantAnswer: Codable, Identifiable, Sendable {
    var id: UUID
    var question: String
    var text: String
    var citations: [AssistantCitation]
    var createdAt: Date

    init(id: UUID = UUID(), question: String, text: String, citations: [AssistantCitation], createdAt: Date = Date()) {
        self.id = id
        self.question = question
        self.text = text
        self.citations = citations
        self.createdAt = createdAt
    }
}

struct AssistantConversation: Codable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var answers: [AssistantAnswer]
    var createdAt: Date
    var updatedAt: Date
    var pinnedAt: Date?

    init(
        id: UUID = UUID(),
        title: String = "New conversation",
        answers: [AssistantAnswer] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        pinnedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.answers = answers
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.pinnedAt = pinnedAt
    }

    static func title(for firstQuestion: String) -> String {
        let singleLine = firstQuestion
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !singleLine.isEmpty else { return "New conversation" }
        let prefix = String(singleLine.prefix(54))
        return prefix.count < singleLine.count ? "\(prefix)…" : prefix
    }
}

enum AssistantConversationPinning {
    static func pinned(
        from conversations: [AssistantConversation]
    ) -> [AssistantConversation] {
        conversations
            .filter { $0.pinnedAt != nil }
            .sorted {
                ($0.pinnedAt ?? .distantPast) > ($1.pinnedAt ?? .distantPast)
            }
    }

    static func updating(
        _ conversation: AssistantConversation,
        isPinned: Bool,
        at date: Date = Date()
    ) -> AssistantConversation {
        var updated = conversation
        updated.pinnedAt = isPinned ? date : nil
        return updated
    }
}

struct PendingAssistantTurn: Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var conversationID: UUID
    var question: String
    var startedAt: Date = Date()
}

struct InterpretedObservation: Codable, Sendable {
    var shouldCreateEvent: Bool
    var event: ActivityEvent?
    var eventIsCommitmentFallback = false
    var commitments: [CommitmentDraft]
    var needsOriginalImage: Bool
    var explanation: String
}

enum FollowUpDraftOperation: String, Codable, Sendable {
    case create
    case update
    case complete
}

struct CommitmentDraft: Codable, Hashable, Sendable {
    var operation: FollowUpDraftOperation
    var existingCommitmentID: UUID?
    var owner: String
    var action: String
    var rationale: String
    var summary: String
    var details: String
    var explicitDueAt: Date?
    var suggestedReviewAt: Date?
    var contextLabel: String?
    var area: FollowUpArea
    var priorityScore: Int
    var priorityReason: String
    var dueSource: FollowUpDueSource?
    var evidenceStrength: FollowUpEvidenceStrength
    var confidence: Double
    var state: CommitmentState

    var dueAt: Date? { explicitDueAt }

    init(
        operation: FollowUpDraftOperation = .create,
        existingCommitmentID: UUID? = nil,
        owner: String,
        action: String,
        rationale: String,
        summary: String = "",
        details: String = "",
        explicitDueAt: Date?,
        suggestedReviewAt: Date?,
        contextLabel: String?,
        area: FollowUpArea = .uncategorized,
        priorityScore: Int = 5,
        priorityReason: String = "",
        dueSource: FollowUpDueSource? = nil,
        evidenceStrength: FollowUpEvidenceStrength = .weak,
        confidence: Double,
        state: CommitmentState = .needsAttention
    ) {
        self.operation = operation
        self.existingCommitmentID = existingCommitmentID
        self.owner = owner
        self.action = action
        self.rationale = rationale
        self.summary = summary
        self.details = details
        self.explicitDueAt = explicitDueAt
        self.suggestedReviewAt = suggestedReviewAt
        self.contextLabel = contextLabel
        self.area = area
        self.priorityScore = min(max(priorityScore, 0), 10)
        self.priorityReason = priorityReason
        self.dueSource = dueSource
        self.evidenceStrength = evidenceStrength
        self.confidence = min(max(confidence, 0), 1)
        self.state = state
    }
}

enum FollowUpMergeRelationship: String, Codable, Hashable, Sendable {
    case related
    case uncertain
    case unrelated
}

struct FollowUpMergeDraft: Codable, Hashable, Sendable {
    var action: String
    var summary: String
    var details: String
    var contextLabel: String
    var area: FollowUpArea
    var priorityScore: Int
    var priorityReason: String
    var dueAt: Date?
    var dueSource: FollowUpDueSource?
    var confidence: Double
    var relationship: FollowUpMergeRelationship
    var relationshipReason: String

    init(
        action: String,
        summary: String,
        details: String,
        contextLabel: String,
        area: FollowUpArea,
        priorityScore: Int,
        priorityReason: String,
        dueAt: Date?,
        dueSource: FollowUpDueSource?,
        confidence: Double,
        relationship: FollowUpMergeRelationship = .related,
        relationshipReason: String = ""
    ) {
        self.action = action
        self.summary = summary
        self.details = details
        self.contextLabel = contextLabel
        self.area = area
        self.priorityScore = min(max(priorityScore, 0), 10)
        self.priorityReason = priorityReason
        self.dueAt = dueAt
        self.dueSource = dueSource
        self.confidence = min(max(confidence, 0), 1)
        self.relationship = relationship
        self.relationshipReason = relationshipReason.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct PendingFollowUpMergeConfirmation: Identifiable, Sendable {
    var id = UUID()
    var sourceIDs: [UUID]
    var targetID: UUID
    var sourceActions: [String]
    var reason: String
    var draft: FollowUpMergeDraft
}
