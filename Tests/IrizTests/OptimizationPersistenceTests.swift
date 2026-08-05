import Foundation
import SQLite3
import Testing
@testable import Iriz

@Suite("Optimization persistence")
struct OptimizationPersistenceTests {
    private let keyData = Data(repeating: 0x51, count: 32)

    @Test("Analysis jobs are unique, leased atomically, and reclaimed after expiry")
    func analysisJobLeases() async throws {
        let directory = temporaryDirectory(named: "AnalysisJobs")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try EncryptedSQLiteStore(directory: directory, keyData: keyData)
        let capturedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let observation = Observation(
            source: .screen,
            capturedAt: capturedAt,
            expiresAt: capturedAt.addingTimeInterval(86_400),
            text: "A durable observation"
        )

        try await store.saveObservation(observation)
        try await store.saveObservation(observation)
        try await store.enqueueAnalysis(observationID: observation.id, at: capturedAt)
        #expect(try await store.pendingAnalysisJobCount() == 1)

        let firstClaim = try await store.claimAnalysisJobs(
            limit: 2,
            now: capturedAt,
            leaseDuration: 600
        )
        #expect(firstClaim.count == 1)
        #expect(firstClaim.first?.attempts == 1)
        #expect(try await store.claimAnalysisJobs(limit: 2, now: capturedAt, leaseDuration: 600).isEmpty)

        let reclaimed = try await store.claimAnalysisJobs(
            limit: 2,
            now: capturedAt.addingTimeInterval(601),
            leaseDuration: 600
        )
        #expect(reclaimed.count == 1)
        #expect(reclaimed.first?.id == firstClaim.first?.id)
        #expect(reclaimed.first?.attempts == 2)

        if let jobID = reclaimed.first?.id {
            try await store.completeAnalysisJob(id: jobID)
        }
        #expect(try await store.pendingAnalysisJobCount() == 0)
    }

    @Test("Credential-blocked jobs resume only after explicit unblocking")
    func credentialBlocking() async throws {
        let directory = temporaryDirectory(named: "CredentialBlocking")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try EncryptedSQLiteStore(directory: directory, keyData: keyData)
        let now = Date(timeIntervalSince1970: 2_000_100_000)
        let observation = Observation(
            source: .screen,
            capturedAt: now,
            expiresAt: now.addingTimeInterval(86_400),
            text: "Observation requiring cloud analysis"
        )
        try await store.saveObservation(observation)
        let claimed = try await store.claimAnalysisJobs(limit: 1, now: now, leaseDuration: 600)
        let job = try #require(claimed.first)

        try await store.rescheduleAnalysisJob(
            id: job.id,
            state: .blockedCredentials,
            nextAttemptAt: .distantFuture,
            errorKind: .credentials,
            errorMessage: nil
        )
        #expect(try await store.claimAnalysisJobs(limit: 1, now: now.addingTimeInterval(3_600), leaseDuration: 600).isEmpty)

        let resumedAt = now.addingTimeInterval(3_601)
        try await store.unblockCredentialAnalysisJobs(at: resumedAt)
        let resumed = try await store.claimAnalysisJobs(limit: 1, now: resumedAt, leaseDuration: 600)
        #expect(resumed.first?.id == job.id)
        #expect(resumed.first?.attempts == 2)
    }

    @Test("Retry policy distinguishes credentials, quota, rate limits, transient failures, and Flex")
    func retryPolicyMatrix() {
        func failure(_ status: Int, _ kind: String, retryAfter: String? = nil) -> OpenAIClientError {
            .requestFailed(OpenAIHTTPFailure(
                status: status,
                errorKind: kind,
                requestID: nil,
                retryAfter: retryAfter
            ))
        }

        #expect(AppState.retryDisposition(
            for: failure(401, "invalid_api_key"), attempts: 1, isFlex: false
        ).state == .blockedCredentials)
        #expect(AppState.retryDisposition(
            for: failure(403, "forbidden"), attempts: 1, isFlex: false
        ).state == .blockedCredentials)
        #expect(AppState.retryDisposition(
            for: failure(429, "insufficient_quota"), attempts: 1, isFlex: false
        ).state == .blockedCredentials)
        #expect(AppState.retryDisposition(
            for: failure(429, "rate_limit_exceeded", retryAfter: "45"), attempts: 1, isFlex: false
        ).state == .retryable)
        #expect(AppState.retryDisposition(
            for: failure(429, "rate_limit_exceeded"), attempts: 3, isFlex: false
        ).state == .terminal)
        #expect(AppState.retryDisposition(
            for: failure(408, "timeout"), attempts: 1, isFlex: false
        ).state == .retryable)
        #expect(AppState.retryDisposition(
            for: failure(503, "server_error"), attempts: 2, isFlex: false
        ).state == .terminal)
        #expect(AppState.retryDisposition(
            for: failure(429, "resource_unavailable"), attempts: 2, isFlex: true
        ).state == .retryable)
        #expect(AppState.retryDisposition(
            for: failure(429, "resource_unavailable"), attempts: 3, isFlex: true
        ).state == .retryable)
        #expect(AppState.retryDisposition(
            for: failure(429, "resource_unavailable"), attempts: 4, isFlex: true
        ).state == .terminal)
        #expect(AppState.retryDisposition(
            for: failure(429, "rate_limit_exceeded"), attempts: 3, isFlex: true
        ).state == .terminal)
        let longRetryAfter = AppState.retryDisposition(
            for: failure(429, "rate_limit_exceeded", retryAfter: "7200"), attempts: 1, isFlex: false
        )
        #expect(longRetryAfter.nextAttemptAt.timeIntervalSince(Date()) > 7_100)
        #expect(OpenAIDurableAttemptContext.base(forDurableAttempt: 1) == 1)
        #expect(OpenAIDurableAttemptContext.base(forDurableAttempt: 2) == 3)
        #expect(OpenAIDurableAttemptContext.base(forDurableAttempt: 3) == 5)
    }

    @Test("Screen and audio jobs are claimed by independent source workers")
    func sourceFilteredAnalysisClaims() async throws {
        let directory = temporaryDirectory(named: "SourceFilteredJobs")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try EncryptedSQLiteStore(directory: directory, keyData: keyData)
        let now = Date(timeIntervalSince1970: 2_000_125_000)
        let screen = Observation(
            source: .screen,
            capturedAt: now,
            expiresAt: now.addingTimeInterval(86_400),
            text: "Screen observation"
        )
        let audio = Observation(
            source: .ambientAudio,
            capturedAt: now,
            expiresAt: now.addingTimeInterval(86_400),
            text: "Audio transcript"
        )
        try await store.saveObservation(screen)
        try await store.saveObservation(audio)

        let screenJobs = try await store.claimAnalysisJobs(
            limit: 1,
            now: now,
            leaseDuration: 600,
            sources: [.screen]
        )
        let audioJobs = try await store.claimAnalysisJobs(
            limit: 1,
            now: now,
            leaseDuration: 600,
            sources: [.ambientAudio, .meetingMicrophone, .meetingSystemAudio]
        )
        #expect(screenJobs.map(\.observationID) == [screen.id])
        #expect(audioJobs.map(\.observationID) == [audio.id])
    }

    @Test("A global OpenAI block survives restart and requires explicit clearing")
    func durableGlobalOpenAIBlock() async throws {
        let directory = temporaryDirectory(named: "GlobalOpenAIBlock")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 2_000_130_000)
        let store = try EncryptedSQLiteStore(directory: directory, keyData: keyData)
        try await store.blockAllOpenAIJobs(
            errorKind: .credentials,
            errorMessage: "spending limit",
            at: now
        )
        #expect(try await store.hasCredentialBlockedOpenAIJobs())

        let reopened = try EncryptedSQLiteStore(directory: directory, keyData: keyData)
        #expect(try await reopened.hasCredentialBlockedOpenAIJobs())
        try await reopened.clearOpenAIWorkBlock(at: now.addingTimeInterval(1))
        #expect(!(try await reopened.hasCredentialBlockedOpenAIJobs()))
    }

    @Test("A privacy purge consumes credential-blocked capture jobs")
    func privacyPurgeIncludesCredentialBlockedJobs() async throws {
        let directory = temporaryDirectory(named: "BlockedPrivacyPurge")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try EncryptedSQLiteStore(directory: directory, keyData: keyData)
        let now = Date(timeIntervalSince1970: 2_000_140_000)
        let screen = Observation(
            source: .screen,
            capturedAt: now,
            expiresAt: now.addingTimeInterval(86_400),
            text: "Private screen content"
        )
        let manual = Observation(
            source: .manualNote,
            capturedAt: now,
            expiresAt: now.addingTimeInterval(86_400),
            text: "Explicit manual note"
        )
        try await store.saveObservation(screen)
        try await store.saveObservation(manual)
        try await store.blockAllOpenAIJobs(
            errorKind: .credentials,
            errorMessage: "credential block",
            at: now
        )

        try await store.discardPendingAnalysisJobs(
            sources: [.screen],
            processedAt: now.addingTimeInterval(1)
        )
        try await store.unblockCredentialAnalysisJobs(at: now.addingTimeInterval(2))
        let screenJobs = try await store.claimAnalysisJobs(
            limit: 10,
            now: now.addingTimeInterval(3),
            leaseDuration: 600,
            sources: [.screen]
        )
        let manualJobs = try await store.claimAnalysisJobs(
            limit: 10,
            now: now.addingTimeInterval(3),
            leaseDuration: 600,
            sources: [.manualNote]
        )

        #expect(screenJobs.isEmpty)
        #expect(try await store.observation(id: screen.id)?.processedAt == now.addingTimeInterval(1))
        #expect(manualJobs.map(\.observationID) == [manual.id])
    }

    @Test("An audio batch atomically replaces its leased raw segment jobs")
    func audioBatchAtomicMaterialization() async throws {
        let directory = temporaryDirectory(named: "AudioBatch")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try EncryptedSQLiteStore(directory: directory, keyData: keyData)
        let now = Date(timeIntervalSince1970: 2_000_150_000)
        let first = Observation(
            source: .meetingMicrophone,
            capturedAt: now,
            expiresAt: now.addingTimeInterval(86_400),
            text: "We should send the proposal.",
            isMeeting: true
        )
        let second = Observation(
            source: .meetingSystemAudio,
            capturedAt: now.addingTimeInterval(1),
            expiresAt: now.addingTimeInterval(86_400),
            text: "We should send the proposal.",
            isMeeting: true
        )
        try await store.saveObservation(first)
        try await store.saveObservation(second)
        #expect(try await store.claimAnalysisJobs(
            limit: 2,
            now: now.addingTimeInterval(2),
            leaseDuration: 600
        ).count == 2)

        let batch = Observation(
            source: .meetingMicrophone,
            capturedAt: now,
            expiresAt: now.addingTimeInterval(86_400),
            text: "We should send the proposal.",
            contentFingerprint: "audio-batch:fixture",
            isMeeting: true
        )
        try await store.saveAudioTranscriptBatchObservation(
            batch,
            consuming: [first.id, second.id],
            processedAt: now.addingTimeInterval(15)
        )

        #expect(try await store.observation(id: first.id)?.processedAt != nil)
        #expect(try await store.observation(id: second.id)?.processedAt != nil)
        #expect(try await store.pendingAnalysisJobCount() == 1)
        let remaining = try await store.claimAnalysisJobs(
            limit: 2,
            now: now.addingTimeInterval(15),
            leaseDuration: 600
        )
        #expect(remaining.map(\.observationID) == [batch.id])

        let reopened = try EncryptedSQLiteStore(directory: directory, keyData: keyData)
        #expect(try await reopened.observation(id: first.id)?.processedAt != nil)
        #expect(try await reopened.observation(id: batch.id)?.processedAt == nil)
    }

    @Test("A semantic analysis commits its event Actions refinement and acknowledgement atomically")
    func atomicAnalysisMutation() async throws {
        let directory = temporaryDirectory(named: "AtomicAnalysis")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try EncryptedSQLiteStore(directory: directory, keyData: keyData)
        let now = Date(timeIntervalSince1970: 2_000_160_000)
        let observation = Observation(
            source: .screen,
            capturedAt: now,
            expiresAt: now.addingTimeInterval(86_400),
            text: "Send the launch brief by Friday"
        )
        let event = ActivityEvent(
            startedAt: now,
            endedAt: now,
            kind: .task,
            status: .inProgress,
            importance: .important,
            title: "Launch brief",
            summary: "The launch brief is being prepared.",
            confidence: 0.9,
            createdAt: now,
            updatedAt: now
        )
        let subject = FollowUpSubject(
            id: "launch-brief",
            name: "Launch brief",
            area: .work,
            color: .indigo,
            createdAt: now,
            updatedAt: now
        )
        let commitment = Commitment(
            eventID: event.id,
            owner: "You",
            action: "Send the launch brief",
            confidence: 0.9,
            state: .needsAttention,
            lifecycle: .active,
            subjectID: subject.id,
            area: .work,
            aiPriorityScore: 8,
            surfacedAt: now
        )
        let refinement = AnalysisRefinementRequest(
            eventID: event.id,
            eventRevision: event.updatedAt,
            isCritical: true,
            notBefore: now
        )
        try await store.saveObservation(observation)
        try await store.applyAnalysisMutation(AnalysisPersistenceMutation(
            observationID: observation.id,
            processedAt: now.addingTimeInterval(1),
            event: event,
            commitments: [commitment, commitment],
            subjects: [subject, subject],
            refinement: refinement
        ))

        #expect(try await store.observation(id: observation.id)?.processedAt == now.addingTimeInterval(1))
        #expect(try await store.pendingAnalysisJobCount() == 0)
        #expect(try await store.event(id: event.id) == event)
        #expect(try await store.commitments(includingClosed: true).map(\.id) == [commitment.id])
        #expect(try await store.followUpSubjects().map(\.id) == [subject.id])
        let jobs = try await store.claimRefinementJobs(
            limit: 2,
            now: now.addingTimeInterval(1),
            leaseDuration: 1_200,
            criticalLeaseDuration: 600
        )
        #expect(jobs.count == 1)
        #expect(jobs.first?.eventID == event.id)

        let reopened = try EncryptedSQLiteStore(directory: directory, keyData: keyData)
        #expect(try await reopened.observation(id: observation.id)?.processedAt != nil)
        #expect(try await reopened.events(limit: 10, importantOnly: false).map(\.id) == [event.id])
        #expect(try await reopened.commitments(includingClosed: true).map(\.id) == [commitment.id])
    }

    @Test("A privacy generation revokes the complete analysis transaction")
    func privacyFenceRejectsStaleAnalysisCommit() async throws {
        let directory = temporaryDirectory(named: "AnalysisPrivacyFence")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try EncryptedSQLiteStore(directory: directory, keyData: keyData)
        let now = Date(timeIntervalSince1970: 2_000_165_000)
        let observation = Observation(
            source: .screen,
            capturedAt: now,
            expiresAt: now.addingTimeInterval(86_400),
            text: "A screen result crossing the privacy boundary"
        )
        let event = ActivityEvent(
            startedAt: now,
            endedAt: now,
            kind: .context,
            status: .observed,
            importance: .normal,
            title: "Stale result",
            summary: "This must not survive the boundary.",
            confidence: 0.8,
            createdAt: now,
            updatedAt: now
        )
        try await store.saveObservation(observation)
        let fence = CaptureCommitFence()
        let authorization = fence.authorization(for: .screen)
        fence.invalidate([.screen])

        await #expect(throws: CancellationError.self) {
            try await store.applyAnalysisMutation(AnalysisPersistenceMutation(
                observationID: observation.id,
                processedAt: now.addingTimeInterval(1),
                event: event,
                captureCommitAuthorization: authorization
            ))
        }

        #expect(try await store.event(id: event.id) == nil)
        #expect(try await store.observation(id: observation.id)?.processedAt == nil)
        #expect(try await store.pendingAnalysisJobCount() == 1)
    }

    @Test("Analysis mutation applies a Commitment update when its durable revision still matches")
    func analysisCommitmentCompareAndSwapSuccess() async throws {
        let directory = temporaryDirectory(named: "AnalysisCommitmentCASSuccess")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try EncryptedSQLiteStore(directory: directory, keyData: keyData)
        let now = Date(timeIntervalSince1970: 2_000_170_000)
        let event = ActivityEvent(
            startedAt: now,
            endedAt: now,
            kind: .task,
            status: .inProgress,
            importance: .normal,
            title: "Proposal",
            summary: "A proposal is being prepared.",
            confidence: 0.9,
            updatedAt: now
        )
        try await store.saveEvent(event)
        let original = Commitment(
            eventID: event.id,
            owner: "You",
            action: "Prepare proposal",
            confidence: 0.9,
            state: .needsAttention,
            updatedAt: now
        )
        try await store.saveCommitment(original)
        let durableOriginal = try #require(
            try await store.commitments(includingClosed: true).first(where: { $0.id == original.id })
        )
        let observation = Observation(
            source: .screen,
            capturedAt: now,
            expiresAt: now.addingTimeInterval(86_400),
            text: "The proposal also needs pricing."
        )
        try await store.saveObservation(observation)

        var aiUpdate = durableOriginal
        aiUpdate.action = "Prepare proposal with pricing"
        aiUpdate.updatedAt = now.addingTimeInterval(1)
        try await store.applyAnalysisMutation(AnalysisPersistenceMutation(
            observationID: observation.id,
            commitments: [aiUpdate],
            expectedCommitmentRevisions: [durableOriginal.id: durableOriginal.updatedAt]
        ))

        let persisted = try #require(
            try await store.commitments(includingClosed: true).first(where: { $0.id == original.id })
        )
        #expect(persisted.action == "Prepare proposal with pricing")
        #expect(persisted.updatedAt == aiUpdate.updatedAt)
        #expect(try await store.observation(id: observation.id)?.processedAt != nil)
        #expect(try await store.pendingAnalysisJobCount() == 0)
    }

    @Test("Analysis mutation ignores a stale Commitment patch after a user correction")
    func analysisCommitmentCompareAndSwapRejectsStalePatch() async throws {
        let directory = temporaryDirectory(named: "AnalysisCommitmentCASStale")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try EncryptedSQLiteStore(directory: directory, keyData: keyData)
        let now = Date(timeIntervalSince1970: 2_000_180_000)
        let event = ActivityEvent(
            startedAt: now,
            endedAt: now,
            kind: .task,
            status: .inProgress,
            importance: .normal,
            title: "Proposal",
            summary: "A proposal is being prepared.",
            confidence: 0.9,
            updatedAt: now
        )
        try await store.saveEvent(event)
        let original = Commitment(
            eventID: event.id,
            owner: "You",
            action: "Prepare proposal",
            confidence: 0.9,
            state: .needsAttention,
            updatedAt: now
        )
        try await store.saveCommitment(original)
        let lunaSnapshot = try #require(
            try await store.commitments(includingClosed: true).first(where: { $0.id == original.id })
        )
        let observation = Observation(
            source: .screen,
            capturedAt: now,
            expiresAt: now.addingTimeInterval(86_400),
            text: "The proposal also needs pricing."
        )
        try await store.saveObservation(observation)

        var userCorrection = lunaSnapshot
        userCorrection.action = "Send the corrected proposal"
        userCorrection.manuallyEditedFields.insert(.action)
        userCorrection.updatedAt = now.addingTimeInterval(1)
        try await store.saveCommitment(userCorrection)

        var staleLunaPatch = lunaSnapshot
        staleLunaPatch.action = "Prepare proposal with pricing"
        staleLunaPatch.updatedAt = now.addingTimeInterval(2)
        try await store.applyAnalysisMutation(AnalysisPersistenceMutation(
            observationID: observation.id,
            commitments: [staleLunaPatch],
            expectedCommitmentRevisions: [lunaSnapshot.id: lunaSnapshot.updatedAt]
        ))

        let persisted = try #require(
            try await store.commitments(includingClosed: true).first(where: { $0.id == original.id })
        )
        #expect(persisted.action == "Send the corrected proposal")
        #expect(persisted.updatedAt == userCorrection.updatedAt)
        #expect(persisted.manuallyEditedFields.contains(.action))
        // The stale patch is ignored without replaying the observation forever.
        #expect(try await store.observation(id: observation.id)?.processedAt != nil)
        #expect(try await store.pendingAnalysisJobCount() == 0)
    }

    @Test("Cancelling a durable audio batch consumes its raw leased jobs")
    func cancelledAudioBatchConsumesRawJobs() async throws {
        let directory = temporaryDirectory(named: "CancelledAudioBatch")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try EncryptedSQLiteStore(directory: directory, keyData: keyData)
        let now = Date(timeIntervalSince1970: 2_000_175_000)
        let observation = Observation(
            source: .ambientAudio,
            capturedAt: now,
            expiresAt: now.addingTimeInterval(86_400),
            text: "A transcript buffered before pause."
        )
        try await store.saveObservation(observation)
        #expect(try await store.claimAnalysisJobs(
            limit: 1,
            now: now,
            leaseDuration: 600
        ).count == 1)

        try await store.discardAnalysisJobs(
            observationIDs: [observation.id],
            processedAt: now.addingTimeInterval(5)
        )

        #expect(try await store.observation(id: observation.id)?.processedAt == now.addingTimeInterval(5))
        #expect(try await store.pendingAnalysisJobCount() == 0)
        #expect(try await store.claimAnalysisJobs(
            limit: 1,
            now: now.addingTimeInterval(601),
            leaseDuration: 600
        ).isEmpty)
    }

    @Test("Refinement enqueue coalesces revisions and keeps critical priority")
    func refinementCoalescing() async throws {
        let directory = temporaryDirectory(named: "RefinementJobs")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try EncryptedSQLiteStore(directory: directory, keyData: keyData)
        let now = Date(timeIntervalSince1970: 2_000_200_000)
        let event = ActivityEvent(
            startedAt: now,
            endedAt: now,
            kind: .research,
            status: .observed,
            importance: .normal,
            title: "Research",
            summary: "Reviewed material",
            confidence: 0.8
        )
        try await store.saveEvent(event)

        try await store.enqueueRefinement(
            eventID: event.id,
            eventRevision: now,
            isCritical: true,
            notBefore: now
        )
        let newerRevision = now.addingTimeInterval(30)
        try await store.enqueueRefinement(
            eventID: event.id,
            eventRevision: newerRevision,
            isCritical: false,
            notBefore: newerRevision
        )

        #expect(try await store.claimRefinementJobs(limit: 2, now: now, leaseDuration: 1_200).isEmpty)
        let claimed = try await store.claimRefinementJobs(
            limit: 2,
            now: newerRevision,
            leaseDuration: 1_200,
            criticalLeaseDuration: 600
        )
        #expect(claimed.count == 1)
        #expect(claimed.first?.eventRevision == newerRevision)
        #expect(claimed.first?.isCritical == true)
        #expect(claimed.first?.leaseExpiresAt == newerRevision.addingTimeInterval(600))
    }

    @Test("An old refinement worker cannot delete or reschedule a newer revision")
    func refinementRevisionGuard() async throws {
        let directory = temporaryDirectory(named: "RefinementRevisionGuard")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try EncryptedSQLiteStore(directory: directory, keyData: keyData)
        let now = Date(timeIntervalSince1970: 2_000_250_000)
        let eventID = UUID()
        try await store.saveEvent(ActivityEvent(
            id: eventID,
            startedAt: now,
            endedAt: now,
            kind: .research,
            status: .observed,
            importance: .important,
            title: "Revision guard",
            summary: "A refinement is already running.",
            confidence: 0.8,
            updatedAt: now
        ))

        try await store.enqueueRefinement(
            eventID: eventID,
            eventRevision: now,
            isCritical: false,
            notBefore: now
        )
        let oldJob = try #require(try await store.claimRefinementJobs(
            limit: 1,
            now: now,
            leaseDuration: 1_200
        ).first)

        let newerRevision = now.addingTimeInterval(30)
        try await store.enqueueRefinement(
            eventID: eventID,
            eventRevision: newerRevision,
            isCritical: true,
            notBefore: newerRevision
        )
        try await store.completeRefinementJob(id: oldJob.id, eventRevision: oldJob.eventRevision)
        try await store.rescheduleRefinementJob(
            id: oldJob.id,
            eventRevision: oldJob.eventRevision,
            state: .terminal,
            nextAttemptAt: .distantFuture,
            errorKind: .server,
            errorMessage: nil
        )

        let current = try await store.claimRefinementJobs(
            limit: 1,
            now: newerRevision,
            leaseDuration: 1_200
        )
        #expect(current.first?.id == oldJob.id)
        #expect(current.first?.eventRevision == newerRevision)
        #expect(current.first?.isCritical == true)
    }

    @Test("Refinement application atomically compares the event revision and acknowledges its job")
    func refinementResultCompareAndSwap() async throws {
        let directory = temporaryDirectory(named: "RefinementResultCAS")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try EncryptedSQLiteStore(directory: directory, keyData: keyData)
        let now = Date(timeIntervalSince1970: 2_000_275_000)

        var event = ActivityEvent(
            startedAt: now,
            endedAt: now,
            kind: .research,
            status: .observed,
            importance: .normal,
            title: "Original",
            summary: "Original summary",
            confidence: 0.8,
            updatedAt: now
        )
        try await store.saveEvent(event)
        try await store.enqueueRefinement(
            eventID: event.id,
            eventRevision: event.updatedAt,
            isCritical: false,
            notBefore: now
        )
        let successfulJob = try #require(try await store.claimRefinementJobs(
            limit: 1,
            now: now,
            leaseDuration: 1_200
        ).first)
        event.title = "AI refined"
        event.updatedAt = now.addingTimeInterval(1)
        #expect(try await store.applyRefinementResult(
            event,
            expectedRevision: successfulJob.eventRevision,
            jobID: successfulJob.id
        ))
        #expect(try await store.event(id: event.id)?.title == "AI refined")
        #expect(try await store.claimRefinementJobs(
            limit: 1,
            now: now.addingTimeInterval(1_201),
            leaseDuration: 1_200
        ).isEmpty)

        let staleRevision = event.updatedAt
        try await store.enqueueRefinement(
            eventID: event.id,
            eventRevision: staleRevision,
            isCritical: false,
            notBefore: event.updatedAt
        )
        let staleJob = try #require(try await store.claimRefinementJobs(
            limit: 1,
            now: event.updatedAt,
            leaseDuration: 1_200
        ).first)
        var userEdited = event
        userEdited.title = "User edit"
        userEdited.updatedAt = now.addingTimeInterval(2)
        try await store.saveEvent(userEdited)
        var staleAIResult = event
        staleAIResult.title = "Late AI result"
        staleAIResult.updatedAt = now.addingTimeInterval(3)

        #expect(!(try await store.applyRefinementResult(
            staleAIResult,
            expectedRevision: staleJob.eventRevision,
            jobID: staleJob.id
        )))
        #expect(try await store.event(id: event.id)?.title == "User edit")
        #expect(try await store.claimRefinementJobs(
            limit: 1,
            now: now.addingTimeInterval(1_300),
            leaseDuration: 1_200
        ).isEmpty)
    }

    @Test("Leaving a meeting makes its coalesced refinement immediately eligible")
    func meetingEndExpeditesRefinement() async throws {
        let directory = temporaryDirectory(named: "MeetingEndRefinement")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try EncryptedSQLiteStore(directory: directory, keyData: keyData)
        let now = Date(timeIntervalSince1970: 2_000_275_000)
        let event = ActivityEvent(
            startedAt: now,
            endedAt: now,
            kind: .meeting,
            status: .observed,
            importance: .normal,
            title: "Project review",
            summary: "A project review is in progress.",
            confidence: 0.8
        )
        try await store.saveEvent(event)
        try await store.enqueueRefinement(
            eventID: event.id,
            eventRevision: event.updatedAt,
            isCritical: false,
            notBefore: now.addingTimeInterval(300)
        )
        #expect(try await store.claimRefinementJobs(
            limit: 1,
            now: now,
            leaseDuration: 1_200
        ).isEmpty)

        try await store.expediteMeetingRefinementJobs(at: now)
        let claimed = try await store.claimRefinementJobs(
            limit: 1,
            now: now,
            leaseDuration: 1_200
        )
        #expect(claimed.map(\.eventID) == [event.id])
    }

    @Test("Usage records deduplicate and retain 30-day detail plus 90-day aggregates")
    func usageRetentionAndAggregation() async throws {
        let directory = temporaryDirectory(named: "Usage")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try EncryptedSQLiteStore(directory: directory, keyData: keyData)
        let now = Date(timeIntervalSince1970: 2_000_300_000)
        let recent = usageRecord(startedAt: now.addingTimeInterval(-10 * 86_400), input: 1_000, output: 500)
        let detailExpired = usageRecord(startedAt: now.addingTimeInterval(-31 * 86_400), input: 2_000, output: 600)
        let aggregateExpired = usageRecord(startedAt: now.addingTimeInterval(-91 * 86_400), input: 3_000, output: 700)

        try await store.saveOpenAIUsageRecords([recent, recent, detailExpired, aggregateExpired])
        let beforePurge = try await store.openAIUsageRecords(since: .distantPast, limit: 20)
        #expect(beforePurge.count == 3)
        #expect(try await store.openAIUsageDailyAggregates(since: .distantPast).count == 3)

        try await store.purgeExpired(now: now, retention: .forever)
        let detail = try await store.openAIUsageRecords(since: .distantPast, limit: 20)
        let aggregates = try await store.openAIUsageDailyAggregates(since: .distantPast)
        #expect(detail.map(\.id) == [recent.id])
        #expect(aggregates.count == 2)
        #expect(aggregates.reduce(0, { $0 + $1.requestCount }) == 2)
        #expect(aggregates.allSatisfy { $0.priceVersion == OpenAICostEstimator.priceVersion })

        let encryptedBytes = try Data(contentsOf: directory.appendingPathComponent("Iriz.sqlite.iriz"))
        #expect(!String(decoding: encryptedBytes, as: UTF8.self).contains(recent.requestedModel))
    }

    @Test("Concurrent usage flushes preserve records appended during persistence")
    func concurrentUsageFlushPreservesInterleavedRecord() async {
        let sink = SuspendedOpenAIUsageSink()
        let recorder = PersistentOpenAIUsageRecorder(maximumBatchSize: 100, flushInterval: 600)
        await recorder.attach(saveHandler: { records in
            await sink.save(records)
        })
        let first = usageRecord(startedAt: Date(), input: 100, output: 20)
        let second = usageRecord(startedAt: Date().addingTimeInterval(1), input: 200, output: 30)
        await recorder.record(first)

        let firstFlush = Task { await recorder.flush() }
        await sink.waitUntilFirstSaveStarts()
        await recorder.record(second)
        let overlappingFlush = Task { await recorder.flush() }
        await sink.releaseFirstSave()
        await firstFlush.value
        await overlappingFlush.value

        #expect(await recorder.bufferedCount() == 0)
        #expect(await sink.savedIDs() == Set([first.id, second.id]))
    }

    @Test("A durable usage flush retries transient failures and retains a persistent tail")
    func durableUsageFlushFailureSemantics() async {
        let transientSink = RetryingOpenAIUsageSink(failuresBeforeSuccess: 2)
        let transientRecorder = PersistentOpenAIUsageRecorder(maximumBatchSize: 100, flushInterval: 600)
        await transientRecorder.attach(saveHandler: { records in
            try await transientSink.save(records)
        })
        let transientRecord = usageRecord(startedAt: Date(), input: 100, output: 20)
        await transientRecorder.record(transientRecord)
        try? await transientRecorder.flushDurably(maxAttempts: 3)
        #expect(await transientSink.attemptCount() == 3)
        #expect(await transientSink.savedIDs() == Set([transientRecord.id]))
        #expect(await transientRecorder.bufferedCount() == 0)

        let persistentSink = RetryingOpenAIUsageSink(failuresBeforeSuccess: .max)
        let persistentRecorder = PersistentOpenAIUsageRecorder(maximumBatchSize: 100, flushInterval: 600)
        await persistentRecorder.attach(saveHandler: { records in
            try await persistentSink.save(records)
        })
        await persistentRecorder.record(usageRecord(startedAt: Date(), input: 200, output: 30))
        await #expect(throws: UsageRecorderFixtureError.self) {
            try await persistentRecorder.flushDurably(maxAttempts: 3)
        }
        #expect(await persistentSink.attemptCount() == 3)
        #expect(await persistentRecorder.bufferedCount() == 1)
    }

    @Test("An older encrypted usage aggregate gains a persisted price version")
    func legacyUsageAggregatePriceMigration() async throws {
        let directory = temporaryDirectory(named: "LegacyUsagePrice")
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeLegacyUsageDatabase(directory: directory)

        let store = try EncryptedSQLiteStore(directory: directory, keyData: keyData)
        let aggregate = try #require(
            try await store.openAIUsageDailyAggregates(since: .distantPast).first
        )
        #expect(aggregate.day == "2033-05-18")
        #expect(aggregate.priceVersion == OpenAICostEstimator.priceVersion)
        #expect(aggregate.requestCount == 3)
        #expect(abs(aggregate.estimatedCostUSD - 0.0042) < 0.000_000_1)

        let reopened = try EncryptedSQLiteStore(directory: directory, keyData: keyData)
        #expect(
            try await reopened.openAIUsageDailyAggregates(since: .distantPast).first?.priceVersion
                == OpenAICostEstimator.priceVersion
        )
    }

    @Test("Shadow qualification comparisons remain encrypted and expire after 30 days")
    func shadowQualificationPersistence() async throws {
        let directory = temporaryDirectory(named: "AppleShadow")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try EncryptedSQLiteStore(directory: directory, keyData: keyData)
        let now = Date(timeIntervalSince1970: 2_000_400_000)
        let fingerprint = AppleModelFingerprint(
            operatingSystemMajor: 26,
            operatingSystemMinor: 5,
            localeIdentifier: "fr-FR",
            promptVersion: "gate-v1",
            schemaVersion: "verdict-v1"
        )
        let record = AppleShadowQualificationRecord(
            observationID: UUID(),
            occurredAt: now.addingTimeInterval(-31 * 86_400),
            modelFingerprint: fingerprint,
            verdict: .clearlyEmpty,
            routeReason: .shadowMode,
            localLatencyMilliseconds: 700,
            generationAttempted: true,
            structuredOutputValid: true,
            cloudMeaningful: true,
            isCriticalCase: false,
            exampleText: "private disagreement fixture"
        )
        try await store.saveAppleShadowQualificationRecord(record)
        #expect(try await store.appleShadowQualificationRecords(since: .distantPast, limit: 10) == [record])

        let encryptedBytes = try Data(contentsOf: directory.appendingPathComponent("Iriz.sqlite.iriz"))
        #expect(!String(decoding: encryptedBytes, as: UTF8.self).contains("private disagreement fixture"))
        try await store.purgeExpired(now: now, retention: .forever)
        #expect(try await store.appleShadowQualificationRecords(since: .distantPast, limit: 10).isEmpty)
    }

    @Test("Apple qualification evaluator enforces every promotion threshold")
    func appleQualificationThresholds() throws {
        let fingerprint = AppleModelFingerprint(
            operatingSystemMajor: 26,
            operatingSystemMinor: 5,
            localeIdentifier: "en-US",
            promptVersion: "gate-v1",
            schemaVersion: "verdict-v1"
        )
        let gateRecords = (0..<1_000).map { index in
            let isLocalEventAttempt = (100..<300).contains(index)
            return AppleShadowQualificationRecord(
                observationID: UUID(),
                modelFingerprint: fingerprint,
                verdict: index < 300 ? .meaningful : .clearlyEmpty,
                routeReason: .shadowMode,
                localLatencyMilliseconds: 800,
                generationAttempted: true,
                structuredOutputValid: true,
                cloudMeaningful: index < 300,
                isCriticalCase: false,
                localEventOutcome: isLocalEventAttempt ? .generated : .notAttempted,
                localEventLatencyMilliseconds: isLocalEventAttempt ? 900 : nil,
                localEventCloudCompatible: isLocalEventAttempt ? true : nil,
                exampleText: nil
            )
        }
        let criticalBypasses = (0..<100).map { _ in
            AppleShadowQualificationRecord(
                observationID: UUID(),
                modelFingerprint: fingerprint,
                verdict: nil,
                routeReason: .highRiskSignal,
                localLatencyMilliseconds: 0,
                generationAttempted: false,
                structuredOutputValid: false,
                cloudMeaningful: true,
                isCriticalCase: true,
                exampleText: nil
            )
        }
        let records = gateRecords + criticalBypasses
        let report = try AppleQualificationEvaluator.report(for: records)
        #expect(report.observationCount == 1_100)
        #expect(report.gateDecisionCount == 1_000)
        #expect(report.criticalBypassViolationCount == 0)
        #expect(report.falseRejectionCount == 0)
        #expect(report.qualifiesGate)
        #expect(report.localEventAttemptCount == 200)
        #expect(report.localEventValidityRate == 1)
        #expect(report.localEventCloudCompatibilityRate == 1)
        #expect(report.localEventLatencyP95Milliseconds == 900)
        #expect(report.qualifiesLocalEvents)

        var unsafeLocalEvent = records
        unsafeLocalEvent[100] = AppleShadowQualificationRecord(
            observationID: UUID(),
            modelFingerprint: fingerprint,
            verdict: .meaningful,
            routeReason: .shadowMode,
            localLatencyMilliseconds: 800,
            generationAttempted: true,
            structuredOutputValid: true,
            cloudMeaningful: true,
            isCriticalCase: false,
            localEventOutcome: .generated,
            localEventLatencyMilliseconds: 900,
            localEventCloudCompatible: false,
            localEventCriticalMismatch: true,
            exampleText: nil
        )
        let unsafeReport = try AppleQualificationEvaluator.report(for: unsafeLocalEvent)
        #expect(unsafeReport.qualifiesGate)
        #expect(!unsafeReport.qualifiesLocalEvents)
        #expect(unsafeReport.localEventCriticalMismatchCount == 1)

        var failing = records
        failing[999] = AppleShadowQualificationRecord(
            observationID: UUID(),
            modelFingerprint: fingerprint,
            verdict: .clearlyEmpty,
            routeReason: .shadowMode,
            localLatencyMilliseconds: 800,
            generationAttempted: true,
            structuredOutputValid: true,
            cloudMeaningful: true,
            isCriticalCase: true,
            exampleText: nil
        )
        #expect(!((try AppleQualificationEvaluator.report(for: failing)).qualifiesGate))
    }

    @Test("Apple qualification cannot dilute gate errors with deterministic bypasses")
    func appleQualificationUsesEligibleDecisionDenominator() throws {
        let fingerprint = AppleModelFingerprint(
            operatingSystemMajor: 26,
            operatingSystemMinor: 5,
            localeIdentifier: "en-US",
            promptVersion: "gate-v1",
            schemaVersion: "verdict-v1"
        )
        let decisions = (0..<100).map { index in
            AppleShadowQualificationRecord(
                observationID: UUID(),
                modelFingerprint: fingerprint,
                verdict: index < 5 ? .clearlyEmpty : .meaningful,
                routeReason: .shadowMode,
                localLatencyMilliseconds: 800,
                generationAttempted: true,
                structuredOutputValid: true,
                cloudMeaningful: true,
                isCriticalCase: false,
                exampleText: nil
            )
        }
        let bypasses = (0..<900).map { _ in
            AppleShadowQualificationRecord(
                observationID: UUID(),
                modelFingerprint: fingerprint,
                verdict: nil,
                routeReason: .highRiskSignal,
                localLatencyMilliseconds: 0,
                generationAttempted: false,
                structuredOutputValid: false,
                cloudMeaningful: true,
                isCriticalCase: true,
                exampleText: nil
            )
        }

        let report = try AppleQualificationEvaluator.report(for: decisions + bypasses)
        #expect(report.observationCount == 1_000)
        #expect(report.gateDecisionCount == 100)
        #expect(report.falseRejectionCount == 5)
        #expect(abs(report.falseRejectionRate - 0.05) < 0.000_001)
        #expect(!report.qualifiesGate)
    }

    @Test("Apple qualification requires a full uncached structured sample")
    func appleQualificationRequiresStructuredVolume() throws {
        let fingerprint = AppleModelFingerprint(
            operatingSystemMajor: 26,
            operatingSystemMinor: 5,
            localeIdentifier: "en-US",
            promptVersion: "gate-v1",
            schemaVersion: "verdict-v1"
        )
        let decisions = (0..<1_000).map { index in
            AppleShadowQualificationRecord(
                observationID: UUID(),
                modelFingerprint: fingerprint,
                verdict: index < 200 ? .meaningful : .clearlyEmpty,
                routeReason: .shadowMode,
                localLatencyMilliseconds: 800,
                generationAttempted: true,
                fromCache: index != 0,
                structuredOutputValid: true,
                cloudMeaningful: index < 200,
                isCriticalCase: false,
                exampleText: nil
            )
        }
        let bypasses = (0..<100).map { _ in
            AppleShadowQualificationRecord(
                observationID: UUID(),
                modelFingerprint: fingerprint,
                verdict: nil,
                routeReason: .highRiskSignal,
                localLatencyMilliseconds: 0,
                generationAttempted: false,
                structuredOutputValid: false,
                cloudMeaningful: true,
                isCriticalCase: true,
                exampleText: nil
            )
        }

        let report = try AppleQualificationEvaluator.report(for: decisions + bypasses)
        #expect(report.gateDecisionCount == 1_000)
        #expect(report.structuredGenerationCount == 1)
        #expect(!report.qualifiesGate)
    }

    private func usageRecord(startedAt: Date, input: Int, output: Int) -> OpenAIUsageRecord {
        OpenAIUsageRecord(
            logicalRequestID: "fixture-logical-request",
            attemptID: UUID(),
            startedAt: startedAt,
            durationSeconds: 0.5,
            task: OpenAITask.observationClassification.rawValue,
            context: IndicatorActivityContext.screen.rawValue,
            requestedModel: OpenAIModelPolicy.frequentAnalysis,
            responseID: "fixture-response",
            actualModel: OpenAIModelPolicy.frequentAnalysis,
            requestedServiceTier: OpenAIServiceTier.default.rawValue,
            actualServiceTier: OpenAIServiceTier.default.rawValue,
            reasoningEffort: OpenAIReasoningEffort.none.rawValue,
            maxOutputTokens: 2_400,
            outcome: .success,
            httpStatus: 200,
            responseStatus: "completed",
            incompleteReason: nil,
            usage: OpenAIResponseUsage(
                inputTokens: input,
                cachedInputTokens: 0,
                cacheWriteTokens: 0,
                outputTokens: output,
                reasoningTokens: 0,
                totalTokens: input + output
            ),
            requestBytes: 400,
            responseBytes: 200,
            imageCount: 0,
            audioDurationSeconds: nil,
            headers: nil,
            errorKind: nil
        )
    }

    private func temporaryDirectory(named suffix: String) -> URL {
        URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("IrizOptimization-\(suffix)-\(UUID().uuidString)", isDirectory: true)
    }

    private func writeLegacyUsageDatabase(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let plaintextURL = directory.appendingPathComponent("legacy-usage.sqlite")
        var database: OpaquePointer?
        let openCode = sqlite3_open_v2(
            plaintextURL.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openCode == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw SQLiteStoreError.openFailed("Unable to create legacy usage fixture")
        }

        var errorPointer: UnsafeMutablePointer<CChar>?
        let sql = """
        CREATE TABLE api_usage_daily (
            day TEXT PRIMARY KEY NOT NULL,
            request_count INTEGER NOT NULL,
            input_tokens INTEGER NOT NULL,
            cached_input_tokens INTEGER NOT NULL,
            cache_write_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL,
            reasoning_tokens INTEGER NOT NULL,
            total_tokens INTEGER NOT NULL,
            estimated_cost_usd REAL NOT NULL
        );
        INSERT INTO api_usage_daily VALUES ('2033-05-18', 3, 1000, 100, 0, 200, 0, 1200, 0.0042);
        """
        let executeCode = sqlite3_exec(database, sql, nil, nil, &errorPointer)
        guard executeCode == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            if let errorPointer { sqlite3_free(errorPointer) }
            sqlite3_close(database)
            throw SQLiteStoreError.sqlite(code: executeCode, message: message, sql: sql)
        }
        guard sqlite3_close(database) == SQLITE_OK else {
            throw SQLiteStoreError.openFailed("Unable to close legacy usage fixture")
        }

        let plaintext = try Data(contentsOf: plaintextURL)
        let encrypted = try CryptoBox(keyData: keyData).seal(
            plaintext,
            authenticating: Data("IrizSQLiteV1".utf8)
        )
        try EncryptedFileWriter.write(
            encrypted,
            to: directory.appendingPathComponent("Iriz.sqlite.iriz")
        )
        try FileManager.default.removeItem(at: plaintextURL)
    }
}

private actor SuspendedOpenAIUsageSink {
    private var saved = Set<UUID>()
    private var firstSaveStarted = false
    private var firstSaveWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func save(_ records: [OpenAIUsageRecord]) async {
        if !firstSaveStarted {
            firstSaveStarted = true
            let waiters = firstSaveWaiters
            firstSaveWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        saved.formUnion(records.map(\.id))
    }

    func waitUntilFirstSaveStarts() async {
        guard !firstSaveStarted else { return }
        await withCheckedContinuation { continuation in
            firstSaveWaiters.append(continuation)
        }
    }

    func releaseFirstSave() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func savedIDs() -> Set<UUID> { saved }
}

private enum UsageRecorderFixtureError: Error {
    case persistenceFailed
}

private actor RetryingOpenAIUsageSink {
    private let failuresBeforeSuccess: Int
    private var attempts = 0
    private var saved = Set<UUID>()

    init(failuresBeforeSuccess: Int) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    func save(_ records: [OpenAIUsageRecord]) throws {
        attempts += 1
        if attempts <= failuresBeforeSuccess {
            throw UsageRecorderFixtureError.persistenceFailed
        }
        saved.formUnion(records.map(\.id))
    }

    func attemptCount() -> Int { attempts }
    func savedIDs() -> Set<UUID> { saved }
}
