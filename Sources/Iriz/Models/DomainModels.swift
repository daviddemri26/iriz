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
    case later
    case waiting
    case maybe
    case completed
    case dismissed

    var displayName: String {
        switch self {
        case .needsAttention: "Needs attention"
        case .later: "Later"
        case .waiting: "Waiting"
        case .maybe: "Maybe"
        case .completed: "Completed"
        case .dismissed: "Dismissed"
        }
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
    var confidence: Double
    var state: CommitmentState
    var linkedEventIDs: [UUID]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        eventID: UUID,
        owner: String,
        action: String,
        rationale: String = "",
        explicitDueAt: Date? = nil,
        suggestedReviewAt: Date? = nil,
        confidence: Double,
        state: CommitmentState,
        linkedEventIDs: [UUID] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.eventID = eventID
        self.owner = owner
        self.action = action
        self.rationale = rationale
        self.explicitDueAt = explicitDueAt
        self.suggestedReviewAt = suggestedReviewAt
        self.confidence = min(max(confidence, 0), 1)
        self.state = state
        self.linkedEventIDs = linkedEventIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
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

struct InterpretedObservation: Codable, Sendable {
    var shouldCreateEvent: Bool
    var event: ActivityEvent?
    var commitments: [CommitmentDraft]
    var needsOriginalImage: Bool
    var explanation: String
}

struct CommitmentDraft: Codable, Hashable, Sendable {
    var owner: String
    var action: String
    var rationale: String
    var explicitDueAt: Date?
    var suggestedReviewAt: Date?
    var confidence: Double
    var state: CommitmentState
}
