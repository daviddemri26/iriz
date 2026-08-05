import Foundation

struct AnalysisRefinementRequest: Equatable, Sendable {
    let eventID: UUID
    let eventRevision: Date
    let isCritical: Bool
    let notBefore: Date
}

/// One all-or-nothing semantic result. The event, Actions, subjects,
/// background refinement, observation marker, and durable job acknowledgement
/// cross the encrypted persistence boundary together.
struct AnalysisPersistenceMutation: Sendable {
    let observationID: UUID
    let processedAt: Date
    let event: ActivityEvent?
    let commitments: [Commitment]
    /// Revision read from durable storage while the analysis mutation gate is
    /// held. Existing commitments are updated only if this revision still
    /// matches; a missing entry means the write is a create-if-absent.
    let expectedCommitmentRevisions: [UUID: Date]
    let subjects: [FollowUpSubject]
    let refinement: AnalysisRefinementRequest?
    let captureCommitAuthorization: CaptureCommitAuthorization?

    init(
        observationID: UUID,
        processedAt: Date = Date(),
        event: ActivityEvent? = nil,
        commitments: [Commitment] = [],
        expectedCommitmentRevisions: [UUID: Date] = [:],
        subjects: [FollowUpSubject] = [],
        refinement: AnalysisRefinementRequest? = nil,
        captureCommitAuthorization: CaptureCommitAuthorization? = nil
    ) {
        self.observationID = observationID
        self.processedAt = processedAt
        self.event = event
        self.commitments = commitments
        self.expectedCommitmentRevisions = expectedCommitmentRevisions
        self.subjects = subjects
        self.refinement = refinement
        self.captureCommitAuthorization = captureCommitAuthorization
    }
}

protocol LogRepository: Sendable {
    func saveObservation(_ observation: Observation) async throws
    func saveObservationWithoutAnalysisJob(_ observation: Observation) async throws
    func saveAudioTranscriptBatchObservation(
        _ observation: Observation,
        consuming observationIDs: [UUID],
        processedAt: Date
    ) async throws
    func markObservationProcessed(id: UUID, at date: Date) async throws
    func applyAnalysisMutation(_ mutation: AnalysisPersistenceMutation) async throws
    func observation(id: UUID) async throws -> Observation?
    func deleteObservation(id: UUID) async throws
    func pendingObservations(limit: Int) async throws -> [Observation]
    func enqueueAnalysis(observationID: UUID, at date: Date) async throws
    func claimAnalysisJobs(
        limit: Int,
        now: Date,
        leaseDuration: TimeInterval,
        sources: [ObservationSource]?
    ) async throws -> [AnalysisJob]
    func completeAnalysisJob(id: UUID) async throws
    func discardAnalysisJobs(observationIDs: [UUID], processedAt: Date) async throws
    func discardPendingAnalysisJobs(sources: [ObservationSource], processedAt: Date) async throws
    func rescheduleAnalysisJob(
        id: UUID,
        state: AnalysisJobState,
        nextAttemptAt: Date,
        errorKind: AnalysisErrorKind?,
        errorMessage: String?
    ) async throws
    func unblockCredentialAnalysisJobs(at date: Date) async throws
    func blockAllOpenAIJobs(errorKind: AnalysisErrorKind, errorMessage: String?, at date: Date) async throws
    func hasCredentialBlockedOpenAIJobs() async throws -> Bool
    func clearOpenAIWorkBlock(at date: Date) async throws
    func pendingAnalysisJobCount() async throws -> Int
    func enqueueRefinement(
        eventID: UUID,
        eventRevision: Date,
        isCritical: Bool,
        notBefore: Date
    ) async throws
    func expediteMeetingRefinementJobs(at date: Date) async throws
    func claimRefinementJobs(
        limit: Int,
        now: Date,
        leaseDuration: TimeInterval,
        criticalLeaseDuration: TimeInterval?
    ) async throws -> [RefinementJob]
    func completeRefinementJob(id: UUID, eventRevision: Date) async throws
    /// Applies a background refinement only while the durable job and event are
    /// still on the revision that was sent to the model. The comparison, event
    /// write, and job acknowledgement must be one repository transaction so a
    /// concurrent user edit can never be overwritten.
    func applyRefinementResult(
        _ event: ActivityEvent,
        expectedRevision: Date,
        jobID: UUID
    ) async throws -> Bool
    func rescheduleRefinementJob(
        id: UUID,
        eventRevision: Date,
        state: AnalysisJobState,
        nextAttemptAt: Date,
        errorKind: AnalysisErrorKind?,
        errorMessage: String?
    ) async throws
    func unblockCredentialRefinementJobs(at date: Date) async throws
    func saveEvent(_ event: ActivityEvent) async throws
    func event(id: UUID) async throws -> ActivityEvent?
    func events(limit: Int, importantOnly: Bool) async throws -> [ActivityEvent]
    func searchEvents(query: String, limit: Int) async throws -> [ActivityEvent]
    func deleteEvent(id: UUID) async throws
    func saveCommitment(_ commitment: Commitment) async throws
    func commitments(includingClosed: Bool) async throws -> [Commitment]
    func replaceCommitments(with mergedCommitment: Commitment, deletingSourceIDs sourceIDs: [UUID]) async throws
    func saveFollowUpSubject(_ subject: FollowUpSubject) async throws
    func followUpSubject(id: String) async throws -> FollowUpSubject?
    func followUpSubjects() async throws -> [FollowUpSubject]
    func deleteFollowUpSubject(id: String) async throws
    func saveFollowUpType(_ type: FollowUpType) async throws
    func followUpTypes() async throws -> [FollowUpType]
    func deleteFollowUpType(id: String) async throws
    func resetFollowUps() async throws
    func saveAssistantConversation(_ conversation: AssistantConversation) async throws
    func assistantConversations(limit: Int) async throws -> [AssistantConversation]
    func deleteAssistantConversation(id: UUID) async throws
    func saveOpenAIUsageRecords(_ records: [OpenAIUsageRecord]) async throws
    func openAIUsageRecords(since: Date, limit: Int) async throws -> [OpenAIUsageRecord]
    func openAIUsageDailyAggregates(since: Date) async throws -> [OpenAIUsageDailyAggregate]
    func saveOptimizationTelemetryRecords(_ records: [OptimizationTelemetryRecord]) async throws
    func optimizationTelemetryRecords(since: Date, limit: Int) async throws -> [OptimizationTelemetryRecord]
    func optimizationTelemetryDailyAggregates(since: Date) async throws -> [OptimizationTelemetryDailyAggregate]
    func saveAppleShadowQualificationRecord(_ record: AppleShadowQualificationRecord) async throws
    func appleShadowQualificationRecords(since: Date, limit: Int) async throws -> [AppleShadowQualificationRecord]
    func purgeExpired(now: Date, retention: StructuredRetention) async throws
    func eventCount() async throws -> Int
}

enum SearchQuery {
    static func ftsExpression(for input: String) -> String? {
        let tokens = input
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 2 }
            .prefix(12)
        guard !tokens.isEmpty else { return nil }
        return tokens
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
            .joined(separator: " OR ")
    }
}
