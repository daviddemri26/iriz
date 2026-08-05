import Foundation

enum AnalysisJobState: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case retryable
    case blockedCredentials
    case terminal
}

enum AnalysisErrorKind: String, Codable, Sendable {
    case credentials
    case rateLimited
    case timeout
    case network
    case server
    case invalidResponse
    case terminalRequest
    case cancelled
    case unknown
}

struct AnalysisJob: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var observationID: UUID
    var state: AnalysisJobState
    var attempts: Int
    var nextAttemptAt: Date
    var leaseExpiresAt: Date?
    var lastErrorKind: AnalysisErrorKind?
    var lastErrorMessage: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        observationID: UUID,
        state: AnalysisJobState = .queued,
        attempts: Int = 0,
        nextAttemptAt: Date = Date(),
        leaseExpiresAt: Date? = nil,
        lastErrorKind: AnalysisErrorKind? = nil,
        lastErrorMessage: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.observationID = observationID
        self.state = state
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt
        self.leaseExpiresAt = leaseExpiresAt
        self.lastErrorKind = lastErrorKind
        self.lastErrorMessage = lastErrorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct RefinementJob: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var eventID: UUID
    var eventRevision: Date
    var isCritical: Bool
    var state: AnalysisJobState
    var attempts: Int
    var nextAttemptAt: Date
    var leaseExpiresAt: Date?
    var lastErrorKind: AnalysisErrorKind?
    var lastErrorMessage: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        eventID: UUID,
        eventRevision: Date,
        isCritical: Bool,
        state: AnalysisJobState = .queued,
        attempts: Int = 0,
        nextAttemptAt: Date,
        leaseExpiresAt: Date? = nil,
        lastErrorKind: AnalysisErrorKind? = nil,
        lastErrorMessage: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.eventID = eventID
        self.eventRevision = eventRevision
        self.isCritical = isCritical
        self.state = state
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt
        self.leaseExpiresAt = leaseExpiresAt
        self.lastErrorKind = lastErrorKind
        self.lastErrorMessage = lastErrorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum AnalysisRetryPolicy {
    static let maximumRateLimitAttempts = 3
    static let maximumTransientAttempts = 2
    // One initial Flex request plus three deferred retries.
    static let maximumFlexAttempts = 4

    static func delay(afterAttempt attempt: Int, retryAfter: TimeInterval? = nil) -> TimeInterval {
        // Retry-After is authoritative. Retrying earlier than the server asks
        // can amplify rate-limit failures and waste requests.
        if let retryAfter, retryAfter > 0 { return retryAfter }
        return switch attempt {
        case ...1: 30
        case 2: 2 * 60
        default: 10 * 60
        }
    }
}
