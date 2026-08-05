import Foundation
import Testing
@testable import Iriz

@Suite("Follow-up intelligence")
struct FollowUpIntelligenceTests {
    @Test("Tile order is surfaced chronology, never priority")
    func chronologicalTileOrder() {
        let oldSurface = Date(timeIntervalSince1970: 1_000)
        let newSurface = Date(timeIntervalSince1970: 2_000)
        let highPriority = commitment(
            action: "High priority older item",
            aiPriorityScore: 10,
            surfacedAt: oldSurface
        )
        var lowPriority = commitment(
            action: "Low priority newer item",
            aiPriorityScore: 1,
            surfacedAt: newSurface
        )
        lowPriority.updatedAt = Date(timeIntervalSince1970: 9_000)

        let ordered = FollowUpPrioritizer.displayOrdered(
            commitments: [highPriority, lowPriority],
            lifecycle: .active
        )

        #expect(ordered.map(\.id) == [lowPriority.id, highPriority.id])
        #expect(FollowUpPrioritizer.displayOrdered(
            commitments: [highPriority, lowPriority],
            lifecycle: .active,
            minimumPriority: 5
        ).map(\.id) == [highPriority.id])
    }

    @Test("An elapsed snooze is considered active without changing persistence")
    func elapsedSnoozeIsDisplayActive() {
        let now = Date(timeIntervalSince1970: 4_000)
        let item = commitment(
            action: "Return after snooze",
            lifecycle: .snoozed,
            aiPriorityScore: 5,
            surfacedAt: Date(timeIntervalSince1970: 3_000),
            snoozedUntil: Date(timeIntervalSince1970: 3_500)
        )

        #expect(FollowUpPrioritizer.effectiveLifecycle(for: item, now: now) == .active)
        #expect(FollowUpPrioritizer.displayOrdered(
            commitments: [item], lifecycle: .active, now: now
        ).map(\.id) == [item.id])
        #expect(item.lifecycle == .snoozed)
    }

    @Test("Related candidates use action, subject, event and entity signals and cap at eight")
    func boundedCandidateSelection() {
        let subject = FollowUpSubject(name: "Atlas", area: .work)
        let queryEvent = event(
            title: "Atlas contract for Morgan",
            summary: "Review the contract terms",
            entities: ["Atlas", "Morgan"]
        )
        let proposed = commitment(
            action: "Review the Atlas contract for Morgan",
            subjectID: subject.id,
            aiPriorityScore: 5,
            surfacedAt: Date(timeIntervalSince1970: 10_000),
            eventID: queryEvent.id
        )
        var events = [queryEvent]
        let candidates = (0..<12).map { index -> Commitment in
            let source = event(
                title: "Atlas contract note \(index)",
                summary: "Morgan contract details",
                entities: ["Atlas", "Morgan"]
            )
            events.append(source)
            return commitment(
                action: "Check Atlas contract section \(index) for Morgan",
                subjectID: subject.id,
                aiPriorityScore: index % 11,
                surfacedAt: Date(timeIntervalSince1970: Double(index)),
                eventID: source.id
            )
        }
        let closed = commitment(
            action: "Review the Atlas contract for Morgan",
            lifecycle: .completed,
            subjectID: subject.id,
            aiPriorityScore: 10,
            surfacedAt: Date(timeIntervalSince1970: 20_000)
        )

        let related = CommitmentLinker.relatedCandidates(
            for: proposed,
            sourceEvent: queryEvent,
            among: candidates + [closed],
            events: events,
            subjects: [subject],
            maximumCount: 50
        )

        #expect(related.count == CommitmentLinker.maximumRelatedCandidates)
        #expect(!related.contains(where: { $0.id == closed.id }))
        #expect(Set(related.map(\.id)).isSubset(of: Set(candidates.map(\.id))))
    }

    @Test("Repeated event identifiers keep the newest evidence without crashing")
    func duplicateEventIdentifiers() {
        let eventID = UUID()
        let older = ActivityEvent(
            id: eventID,
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_010),
            kind: .context,
            status: .observed,
            importance: .normal,
            title: "Older Atlas note",
            summary: "Initial context",
            confidence: 0.7,
            updatedAt: Date(timeIntervalSince1970: 1_010)
        )
        let newer = ActivityEvent(
            id: eventID,
            startedAt: Date(timeIntervalSince1970: 2_000),
            endedAt: Date(timeIntervalSince1970: 2_010),
            kind: .task,
            status: .inProgress,
            importance: .important,
            title: "Review the Atlas contract",
            summary: "Morgan sent the revised contract",
            entities: ["Atlas", "Morgan"],
            confidence: 0.95,
            updatedAt: Date(timeIntervalSince1970: 2_010)
        )
        let candidate = commitment(
            action: "Review the Atlas contract for Morgan",
            aiPriorityScore: 7,
            surfacedAt: Date(timeIntervalSince1970: 1_500),
            eventID: eventID
        )
        let proposed = commitment(
            action: "Check the revised Atlas contract",
            aiPriorityScore: 6,
            surfacedAt: Date(timeIntervalSince1970: 2_010),
            eventID: UUID()
        )
        let duplicatedEvents = [older, newer, older]

        let eventCandidates = CommitmentLinker.relatedCandidates(
            for: newer,
            among: [candidate],
            events: duplicatedEvents
        )
        let proposedCandidates = CommitmentLinker.relatedCandidates(
            for: proposed,
            sourceEvent: newer,
            among: [candidate],
            events: duplicatedEvents
        )
        let ranked = FollowUpPrioritizer.ranked(
            commitments: [candidate],
            events: duplicatedEvents
        )

        #expect(eventCandidates.map(\.id) == [candidate.id])
        #expect(proposedCandidates.map(\.id) == [candidate.id])
        #expect(ranked.map(\.id) == [candidate.id])
    }

    @Test("Subject aliases resolve and unknown labels create a stable subject")
    func subjectResolutionAndCreation() {
        let work = FollowUpSubject(
            name: "Acme Launch",
            area: .work,
            aliases: ["Project Phoenix"]
        )
        #expect(FollowUpContextGrouper.resolveSubject(
            named: "PROJECT PHOENIX",
            in: [work]
        )?.id == work.id)

        let now = Date(timeIntervalSince1970: 5_000)
        let resolution = FollowUpContextGrouper.resolveOrCreateSubject(
            named: "Summer Trip",
            area: .personal,
            in: [work],
            now: now
        )
        #expect(resolution.wasCreated)
        #expect(resolution.subject.id == "summer-trip")
        #expect(resolution.subject.area == .personal)
        #expect(resolution.subjects.count == 2)
        #expect(resolution.subject.createdAt == now)
    }

    @Test("Generic areas resolve to concrete reusable project and family subjects")
    func concreteSubjectDerivation() {
        let websiteEvent = ActivityEvent(
            startedAt: Date(timeIntervalSince1970: 5_100),
            endedAt: Date(timeIntervalSince1970: 5_130),
            kind: .task,
            status: .inProgress,
            importance: .important,
            title: "Lafayette Consulting About page",
            summary: "Work on the company website",
            entities: ["Lafayette Consulting"],
            urls: [URL(string: "https://lafayette-consulting.example/about")!],
            confidence: 0.95
        )
        let genericWork = FollowUpSubject(name: "Work", area: .work)
        let concreteWebsite = FollowUpSubject(name: "Lafayette Consulting Website", area: .work)
        let websiteCommitment = Commitment(
            eventID: websiteEvent.id,
            owner: "You",
            action: "Rewrite the website About page",
            contextLabel: "Work",
            confidence: 0.9,
            state: .needsAttention,
            subjectID: genericWork.id,
            area: .work
        )
        let websiteResolution = FollowUpContextGrouper.resolveOrCreateSubject(
            for: websiteCommitment,
            event: websiteEvent,
            in: [genericWork, concreteWebsite]
        )

        #expect(websiteResolution.subject.id == concreteWebsite.id)
        #expect(websiteResolution.subject.name == "Lafayette Consulting Website")
        #expect(websiteResolution.subject.area == .work)

        let childrenCommitment = Commitment(
            eventID: UUID(),
            owner: "You",
            action: "Register the kids for their school activities",
            confidence: 0.9,
            state: .needsAttention,
            area: .personal
        )
        let childrenResolution = FollowUpContextGrouper.resolveOrCreateSubject(
            for: childrenCommitment,
            event: nil,
            in: []
        )
        #expect(childrenResolution.subject.name == "Kids Activities")
        #expect(childrenResolution.subject.area == .personal)

        let uncategorized = FollowUpContextGrouper.specificSubjectLabel(
            suggested: nil,
            action: "Review this later",
            area: .uncategorized
        )
        #expect(uncategorized == "Uncategorized")
    }

    @Test("Snoozing preserves the follow-up due date")
    func snoozePreservesDueDate() {
        let dueAt = Date(timeIntervalSince1970: 20_000)
        let wakeAt = Date(timeIntervalSince1970: 15_000)
        var item = commitment(
            action: "Send the proposal",
            explicitDueAt: dueAt,
            dueSource: .explicitEvidence,
            aiPriorityScore: 7,
            surfacedAt: Date(timeIntervalSince1970: 10_000)
        )
        item.snoozedUntil = wakeAt
        item.setLifecycle(.snoozed, actor: .user, now: Date(timeIntervalSince1970: 11_000))
        item.snoozedUntil = wakeAt

        #expect(item.dueAt == dueAt)
        #expect(item.dueSource == .explicitEvidence)
        #expect(item.snoozedUntil == wakeAt)
    }

    @Test("Priority personalization clamps scores and learns local corrections")
    func priorityPersonalization() {
        let surfacedAt = Date(timeIntervalSince1970: 6_000)
        let subject = FollowUpSubject(name: "Important client", priorityBias: 2.4)
        let item = commitment(
            action: "Send proposal",
            subjectID: subject.id,
            aiPriorityScore: 4,
            surfacedAt: surfacedAt
        )

        #expect(FollowUpPrioritizer.personalizedScore(aiScore: 9, subject: subject) == 10)
        let correction = FollowUpPrioritizer.applyingUserPriority(
            10,
            aiScore: 4,
            to: item,
            subject: subject,
            now: Date(timeIntervalSince1970: 6_100)
        )
        #expect(correction.commitment.priorityScore == 10)
        #expect(correction.commitment.aiPriorityScore == 4)
        #expect(correction.commitment.displayPriorityScore == 6)
        #expect(correction.commitment.surfacedAt == surfacedAt)
        #expect(correction.commitment.manuallyEditedFields.contains(.priority))
        #expect(correction.subject.correctionCount == 1)
        #expect(abs(correction.subject.priorityBias - 3) < 0.001)

        let ignoredAIUpdate = FollowUpPrioritizer.applyingAIPriority(
            1,
            reason: "Lower confidence",
            to: correction.commitment,
            subject: correction.subject
        )
        #expect(ignoredAIUpdate.priorityScore == 10)
    }

    @Test("Strong explicit completion evidence completes automatically at 0.82")
    func automaticCompletion() throws {
        let created = Date(timeIntervalSince1970: 7_000)
        let item = commitment(
            action: "Pay August rent to Park View",
            aiPriorityScore: 8,
            surfacedAt: created,
            createdAt: created
        )
        let proof = event(
            title: "August rent paid to Park View",
            summary: "The August rent payment was completed",
            status: .completed,
            confidence: 0.98,
            startedAt: created.addingTimeInterval(60)
        )

        let linked = try #require(CommitmentLinker.linking(
            item,
            to: proof,
            automaticCompletionThreshold: 0.82,
            now: created.addingTimeInterval(120)
        ))
        #expect(linked.lifecycle == .completed)
        #expect(linked.completionActor == .iriz)
        #expect(linked.completionEvidence?.strength == .explicit)
        #expect(linked.evidenceHint == nil)
        #expect(linked.surfacedAt == item.surfacedAt)
    }

    @Test("Weak completion evidence keeps the follow-up open with a hint")
    func weakCompletionHint() throws {
        let created = Date(timeIntervalSince1970: 8_000)
        let item = commitment(
            action: "Send the camera specification document to Morgan",
            aiPriorityScore: 6,
            surfacedAt: created,
            createdAt: created
        )
        let proof = event(
            title: "Camera document archived",
            summary: "The camera document is in the outgoing folder",
            status: .completed,
            confidence: 0.9,
            startedAt: created.addingTimeInterval(60)
        )

        let linked = try #require(CommitmentLinker.linking(
            item,
            to: proof,
            suggestionThreshold: 0.5,
            now: created.addingTimeInterval(120)
        ))
        #expect(linked.lifecycle == .active)
        #expect(linked.completionEvidence?.strength == .weak)
        #expect(linked.evidenceHint?.contains("Camera document archived") == true)
        #expect(linked.history.last?.kind == .evidence)
    }

    @Test("Merge field resolution is deterministic and does not delete sources")
    func deterministicMergeFields() throws {
        let early = Date(timeIntervalSince1970: 10_000)
        let manualDue = Date(timeIntervalSince1970: 30_000)
        let explicitDue = Date(timeIntervalSince1970: 20_000)
        let firstHistory = FollowUpHistoryEntry(
            kind: .created,
            actor: .iriz,
            summary: "First created",
            occurredAt: early
        )
        let secondHistory = FollowUpHistoryEntry(
            kind: .edited,
            actor: .user,
            summary: "Second edited",
            occurredAt: early.addingTimeInterval(10)
        )
        let target = commitment(
            action: "Target action",
            explicitDueAt: explicitDue,
            dueSource: .explicitEvidence,
            aiPriorityScore: 9,
            surfacedAt: early,
            history: [firstHistory]
        )
        let source = commitment(
            action: "Source action",
            explicitDueAt: manualDue,
            dueSource: .user,
            userPriorityScore: 10,
            aiPriorityScore: 5,
            surfacedAt: early.addingTimeInterval(100),
            manuallyEditedFields: [.dueDate, .priority],
            history: [secondHistory]
        )

        let fields = try #require(FollowUpMergeResolver.mergedFields(from: [source, target]))
        #expect(fields.explicitDueAt == manualDue)
        #expect(fields.dueSource == .user)
        #expect(fields.userPriorityScore == 10)
        #expect(fields.surfacedAt == source.surfacedAt)
        #expect(fields.linkedEventIDs.contains(target.eventID))
        #expect(fields.linkedEventIDs.contains(source.eventID))
        #expect(fields.history.map(\.id) == [firstHistory.id, secondHistory.id])

        let merged = FollowUpMergeResolver.applyingMergedFields(
            to: target,
            sources: [source],
            now: early.addingTimeInterval(200)
        )
        #expect(merged.id == target.id)
        #expect(merged.history.last?.kind == .merged)
        #expect(target.id != source.id)
    }

    @Test("Merge selection excludes closed items and AI preserves manual target text")
    func safeMergeSelectionAndContent() {
        let time = Date(timeIntervalSince1970: 40_000)
        var manualTarget = commitment(
            action: "Keep this exact action",
            aiPriorityScore: 6,
            surfacedAt: time,
            manuallyEditedFields: [.action, .summary, .details]
        )
        manualTarget.summary = "User summary"
        manualTarget.details = "User notes"
        var activeSource = commitment(
            action: "Second active action",
            aiPriorityScore: 5,
            surfacedAt: time.addingTimeInterval(1),
            manuallyEditedFields: [.action, .details]
        )
        activeSource.details = "Keep this source note verbatim"
        manualTarget.contextLabel = "Client Acme"
        activeSource.contextLabel = "Website Redesign"
        let snoozed = commitment(
            action: "Do not merge this snoozed item",
            lifecycle: .snoozed,
            aiPriorityScore: 7,
            surfacedAt: time.addingTimeInterval(2),
            snoozedUntil: time.addingTimeInterval(3_600)
        )
        let dismissed = commitment(
            action: "Do not merge this dismissed item",
            lifecycle: .dismissed,
            aiPriorityScore: 1,
            surfacedAt: time.addingTimeInterval(3)
        )

        let selection = FollowUpMergeResolver.activeSelection(
            ids: [manualTarget.id, snoozed.id, activeSource.id, dismissed.id, manualTarget.id],
            from: [manualTarget, activeSource, snoozed, dismissed]
        )
        #expect(selection.sourceIDs == [manualTarget.id, activeSource.id])

        let rewritten = FollowUpMergeResolver.applyingAIContent(
            FollowUpMergeDraft(
                action: "AI replacement",
                summary: "AI summary",
                details: "AI details",
                contextLabel: "Client Acme",
                area: .work,
                priorityScore: 8,
                priorityReason: "Urgent",
                dueAt: nil,
                dueSource: nil,
                confidence: 0.9
            ),
            to: manualTarget,
            preserving: selection.commitments
        )
        #expect(rewritten.action == "Keep this exact action")
        #expect(rewritten.summary == "User summary")
        #expect(rewritten.details.contains("User notes"))
        #expect(rewritten.details.contains("Action: Second active action"))
        #expect(rewritten.details.contains("Details: Keep this source note verbatim"))
        #expect(rewritten.details.contains("Subject: Client Acme"))
        #expect(rewritten.details.contains("Subject: Website Redesign"))
        #expect(rewritten.details.contains("Merged source follow-ups:"))
        #expect(rewritten.manuallyEditedFields.contains(.details))
    }

    @Test("Tile opacity is full from six and decreases only from five to zero")
    func tileOpacityThresholds() {
        #expect(FollowUpTilePresentation.tileHeight == 205)
        #expect(FollowUpTilePresentation.scheduleSlotHeight == 24)
        for score in 6...10 {
            #expect(FollowUpTilePresentation.baseOpacity(for: score) == 1)
        }
        #expect(FollowUpTilePresentation.baseOpacity(for: 5) == 0.88)
        #expect(FollowUpTilePresentation.baseOpacity(for: 4) == 0.76)
        #expect(FollowUpTilePresentation.baseOpacity(for: 3) == 0.64)
        #expect(FollowUpTilePresentation.baseOpacity(for: 2) == 0.52)
        #expect(FollowUpTilePresentation.baseOpacity(for: 1) == 0.40)
        #expect(FollowUpTilePresentation.baseOpacity(for: 0) == 0.28)
        #expect(FollowUpTilePresentation.priorityBand(for: 10) == .critical)
        #expect(FollowUpTilePresentation.priorityBand(for: 9) == .critical)
        #expect(FollowUpTilePresentation.priorityBand(for: 8) == .elevated)
        #expect(FollowUpTilePresentation.priorityBand(for: 7) == .elevated)
        #expect(FollowUpTilePresentation.priorityBand(for: 6) == .standard)
    }

    @Test("Only clearly unrelated merges require user confirmation")
    func unrelatedMergeConfirmationGate() throws {
        let time = Date(timeIntervalSince1970: 50_000)
        let first = commitment(action: "Prepare the client proposal", aiPriorityScore: 8, surfacedAt: time)
        let second = commitment(action: "Book the kids' dentist", aiPriorityScore: 5, surfacedAt: time.addingTimeInterval(1))
        let selection = FollowUpMergeResolver.activeSelection(
            ids: [first.id, second.id],
            from: [first, second]
        )
        let base = FollowUpMergeDraft(
            action: "Combined action",
            summary: "",
            details: "",
            contextLabel: "Uncategorized",
            area: .uncategorized,
            priorityScore: 8,
            priorityReason: "",
            dueAt: nil,
            dueSource: nil,
            confidence: 0.9
        )

        #expect(FollowUpMergeResolver.confirmationWarning(for: base, selection: selection, targetID: first.id) == nil)
        var uncertain = base
        uncertain.relationship = .uncertain
        #expect(FollowUpMergeResolver.confirmationWarning(for: uncertain, selection: selection, targetID: first.id) == nil)
        var unrelated = base
        unrelated.relationship = .unrelated
        unrelated.relationshipReason = "The obligations concern different people and outcomes."
        let warning = try #require(
            FollowUpMergeResolver.confirmationWarning(for: unrelated, selection: selection, targetID: first.id)
        )
        #expect(warning.sourceIDs == [first.id, second.id])
        #expect(warning.reason == unrelated.relationshipReason)
        #expect(warning.draft == unrelated)
    }

    private func commitment(
        action: String,
        lifecycle: FollowUpLifecycle = .active,
        subjectID: String? = nil,
        explicitDueAt: Date? = nil,
        dueSource: FollowUpDueSource? = nil,
        userPriorityScore: Int? = nil,
        aiPriorityScore: Int,
        surfacedAt: Date,
        snoozedUntil: Date? = nil,
        createdAt: Date? = nil,
        manuallyEditedFields: Set<FollowUpEditableField> = [],
        history: [FollowUpHistoryEntry] = [],
        eventID: UUID = UUID()
    ) -> Commitment {
        let creation = createdAt ?? surfacedAt
        return Commitment(
            eventID: eventID,
            owner: "You",
            action: action,
            explicitDueAt: explicitDueAt,
            confidence: 0.9,
            state: lifecycle.legacyState,
            createdAt: creation,
            updatedAt: creation,
            lifecycle: lifecycle,
            subjectID: subjectID,
            aiPriorityScore: aiPriorityScore,
            userPriorityScore: userPriorityScore,
            surfacedAt: surfacedAt,
            snoozedUntil: snoozedUntil,
            dueSource: dueSource,
            manuallyEditedFields: manuallyEditedFields,
            history: history
        )
    }

    private func event(
        title: String,
        summary: String,
        entities: [String] = [],
        status: EventStatus = .inProgress,
        confidence: Double = 0.9,
        startedAt: Date = Date(timeIntervalSince1970: 9_000)
    ) -> ActivityEvent {
        ActivityEvent(
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(30),
            kind: .task,
            status: status,
            importance: .important,
            title: title,
            summary: summary,
            entities: entities,
            confidence: confidence
        )
    }
}
