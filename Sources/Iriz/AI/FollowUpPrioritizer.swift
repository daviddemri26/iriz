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

enum FollowUpPrioritizer {
    static let compactListLimit = 8
    static let highlightedLimit = 5

    static func sections(
        commitments: [Commitment],
        events: [ActivityEvent],
        sensitivity: FollowUpSensitivity = .balanced,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [FollowUpSection] {
        let ranked = ranked(
            commitments: commitments,
            events: events,
            sensitivity: sensitivity,
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
        sensitivity: FollowUpSensitivity = .balanced,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [RankedCommitment] {
        let eventsByID = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        let visibleCommitments = commitments.filter { commitment in
            isVisible(commitment, event: eventsByID[commitment.eventID], sensitivity: sensitivity)
        }
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
            let lhsDate = lhs.0.explicitDueAt ?? lhs.0.suggestedReviewAt ?? .distantFuture
            let rhsDate = rhs.0.explicitDueAt ?? rhs.0.suggestedReviewAt ?? .distantFuture
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

    static func isVisible(
        _ commitment: Commitment,
        event: ActivityEvent?,
        sensitivity: FollowUpSensitivity
    ) -> Bool {
        if commitment.state == .dismissed { return false }
        if commitment.isPriority { return true }
        if commitment.state == .completed || commitment.state == .completionSuggested { return true }
        return sensitivity.accepts(
            confidence: commitment.confidence,
            importance: event?.importance ?? .normal,
            hasExplicitDueDate: commitment.explicitDueAt != nil
        )
    }

    private static func effectiveState(for commitment: Commitment, now: Date) -> CommitmentState {
        guard commitment.state == .later || commitment.state == .waiting,
              let reviewAt = commitment.explicitDueAt ?? commitment.suggestedReviewAt,
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
        let reviewAt = commitment.explicitDueAt ?? commitment.suggestedReviewAt
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
        if let review = commitment.suggestedReviewAt {
            if review <= now { return "Ready to review" }
            if review.timeIntervalSince(now) < 7 * 86_400 { return "Review soon" }
            return "Review scheduled"
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
