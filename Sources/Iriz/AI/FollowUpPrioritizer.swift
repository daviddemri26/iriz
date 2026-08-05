import Foundation

struct RankedCommitment: Identifiable, Sendable {
    var id: UUID { commitment.id }
    let commitment: Commitment
    let effectiveState: CommitmentState
    let score: Double
    let reason: String
    let isHighlighted: Bool
}

struct FollowUpSection: Identifiable, Sendable {
    var id: CommitmentState { state }
    let state: CommitmentState
    let commitments: [RankedCommitment]
}

struct FollowUpPriorityCorrection: Sendable {
    let commitment: Commitment
    let subject: FollowUpSubject
}

enum FollowUpPrioritizer {
    static let compactListLimit = 8
    static let highlightedLimit = 5

    static func effectiveLifecycle(
        for commitment: Commitment,
        now: Date = Date()
    ) -> FollowUpLifecycle {
        if commitment.lifecycle == .snoozed,
           let snoozedUntil = commitment.snoozedUntil,
           snoozedUntil <= now {
            return .active
        }
        return commitment.lifecycle
    }

    /// Returns the tile display order. Priority is intentionally only a filter
    /// and visual signal; it never changes chronology.
    static func displayOrdered(
        commitments: [Commitment],
        lifecycle: FollowUpLifecycle? = nil,
        minimumPriority: Int = 0,
        now: Date = Date()
    ) -> [Commitment] {
        let threshold = clampedScore(minimumPriority)
        return commitments
            .filter { commitment in
                commitment.priorityScore >= threshold
                    && (lifecycle.map { effectiveLifecycle(for: commitment, now: now) == $0 } ?? true)
            }
            .sorted(by: chronologicalOrder)
    }

    static func personalizedScore(
        aiScore: Int,
        subject: FollowUpSubject?
    ) -> Int {
        let adjusted = Double(clampedScore(aiScore)) + (subject?.priorityBias ?? 0)
        return clampedScore(Int(adjusted.rounded()))
    }

    static func applyingAIPriority(
        _ aiScore: Int,
        reason: String,
        to commitment: Commitment,
        subject: FollowUpSubject?
    ) -> Commitment {
        var updated = commitment
        guard !commitment.manuallyEditedFields.contains(.priority),
              commitment.userPriorityScore == nil else {
            return updated
        }
        updated.aiPriorityScore = clampedScore(aiScore)
        updated.displayPriorityScore = personalizedScore(aiScore: aiScore, subject: subject)
        updated.priorityReason = reason
        return updated
    }

    static func applyingUserPriority(
        _ userScore: Int,
        aiScore: Int,
        to commitment: Commitment,
        subject: FollowUpSubject,
        now: Date = Date()
    ) -> FollowUpPriorityCorrection {
        let correctedScore = clampedScore(userScore)
        let normalizedAIScore = clampedScore(aiScore)
        var updatedCommitment = commitment
        var updatedSubject = subject
        updatedSubject.learn(aiScore: normalizedAIScore, userScore: correctedScore)
        updatedSubject.updatedAt = now
        updatedCommitment.aiPriorityScore = normalizedAIScore
        updatedCommitment.displayPriorityScore = personalizedScore(aiScore: normalizedAIScore, subject: subject)
        updatedCommitment.userPriorityScore = correctedScore
        updatedCommitment.manuallyEditedFields.insert(.priority)
        updatedCommitment.updatedAt = now
        updatedCommitment.history.append(FollowUpHistoryEntry(
            kind: .prioritized,
            actor: .user,
            summary: "Priority changed to \(correctedScore)",
            occurredAt: now
        ))
        return FollowUpPriorityCorrection(commitment: updatedCommitment, subject: updatedSubject)
    }

    static func sections(
        commitments: [Commitment],
        events: [ActivityEvent],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [FollowUpSection] {
        let ranked = ranked(
            commitments: commitments,
            events: events,
            now: now,
            calendar: calendar
        )
        return [CommitmentState.completionSuggested, .needsAttention, .waiting, .later, .maybe, .completed].compactMap { state in
            let values = ranked.filter { $0.effectiveState == state }
            return values.isEmpty ? nil : FollowUpSection(state: state, commitments: values)
        }
    }

    static func ranked(
        commitments: [Commitment],
        events: [ActivityEvent],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [RankedCommitment] {
        let eventsByID = Dictionary(events.map { ($0.id, $0) }) { lhs, rhs in
            lhs.updatedAt >= rhs.updatedAt ? lhs : rhs
        }
        // Granularity controls how future follow-ups are created. It must never
        // hide or retroactively reshape items that already exist.
        let visibleCommitments = commitments.filter { $0.state != .dismissed }
        let evaluated = visibleCommitments.map { commitment -> (Commitment, CommitmentState, Double, String) in
            let state = effectiveState(for: commitment, now: now)
            return (
                commitment,
                state,
                score(for: commitment, effectiveState: state, event: eventsByID[commitment.eventID], now: now),
                reason(for: commitment, effectiveState: state, now: now, calendar: calendar)
            )
        }
        .sorted { lhs, rhs in
            if lhs.2 != rhs.2 { return lhs.2 > rhs.2 }
            let lhsDate = lhs.0.explicitDueAt ?? .distantFuture
            let rhsDate = rhs.0.explicitDueAt ?? .distantFuture
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            return lhs.0.updatedAt > rhs.0.updatedAt
        }

        let openEvaluated = evaluated.filter { $0.1 != .completed && $0.1 != .dismissed }
        let highlightedIDs = openEvaluated.count > compactListLimit
            ? Set(openEvaluated.prefix(highlightedLimit).map { $0.0.id })
            : Set(openEvaluated.map { $0.0.id })
        return evaluated.map {
            RankedCommitment(
                commitment: $0.0,
                effectiveState: $0.1,
                score: $0.2,
                reason: $0.3,
                isHighlighted: highlightedIDs.contains($0.0.id)
            )
        }
    }

    private static func chronologicalOrder(_ lhs: Commitment, _ rhs: Commitment) -> Bool {
        if lhs.surfacedAt != rhs.surfacedAt { return lhs.surfacedAt > rhs.surfacedAt }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func clampedScore(_ score: Int) -> Int {
        min(max(score, 0), 10)
    }

    private static func effectiveState(for commitment: Commitment, now: Date) -> CommitmentState {
        guard commitment.state == .later || commitment.state == .waiting,
              let reviewAt = commitment.explicitDueAt,
              reviewAt <= now else {
            return commitment.state
        }
        return .needsAttention
    }

    private static func score(
        for commitment: Commitment,
        effectiveState: CommitmentState,
        event: ActivityEvent?,
        now: Date
    ) -> Double {
        let stateScore: Double = switch effectiveState {
        case .completionSuggested: 86
        case .needsAttention: 70
        case .waiting: 32
        case .later: 24
        case .maybe: 8
        case .completed, .dismissed: 0
        }
        let reviewAt = commitment.explicitDueAt
        let timingScore: Double
        if let reviewAt {
            let interval = reviewAt.timeIntervalSince(now)
            switch interval {
            case ..<0: timingScore = 90 + min(abs(interval) / 86_400, 30)
            case 0..<(24 * 3_600): timingScore = 65
            case 0..<(7 * 86_400): timingScore = 42
            case 0..<(30 * 86_400): timingScore = 20
            default: timingScore = 5
            }
        } else {
            timingScore = 0
        }
        let importanceScore = Double(event?.importance.rawValue ?? 0) * 12
        let confidenceScore = commitment.confidence * 18
        let evidenceScore = min(Double(commitment.linkedEventIDs.count) * 3, 9)
        let manualPriorityScore = commitment.isPriority ? 1_000.0 : 0
        return manualPriorityScore + stateScore + timingScore + importanceScore + confidenceScore + evidenceScore
    }

    private static func reason(
        for commitment: Commitment,
        effectiveState: CommitmentState,
        now: Date,
        calendar: Calendar
    ) -> String {
        if commitment.isPriority, effectiveState != .completed { return "Marked as priority" }
        if effectiveState == .completionSuggested { return "Completion evidence found" }
        if effectiveState == .completed {
            return commitment.rationale.contains("Automatically completed") ? "Completed automatically" : "Completed"
        }
        if let due = commitment.explicitDueAt {
            if due < now { return "Due date passed" }
            if calendar.isDateInToday(due) { return "Due today" }
            if due.timeIntervalSince(now) < 7 * 86_400 { return "Due soon" }
            return "Explicit due date"
        }
        return switch effectiveState {
        case .completionSuggested: "Completion evidence found"
        case .needsAttention: "Ready for follow-up"
        case .waiting: "Waiting for evidence"
        case .later: "Saved for later"
        case .maybe: "Needs confirmation"
        case .completed, .dismissed: "Closed"
        }
    }
}
