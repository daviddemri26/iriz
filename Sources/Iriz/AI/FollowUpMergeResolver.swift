import Foundation

struct FollowUpMergeFields: Sendable {
    let explicitDueAt: Date?
    let suggestedReviewAt: Date?
    let dueSource: FollowUpDueSource?
    let dueConfidence: Double?
    let aiPriorityScore: Int
    let displayPriorityScore: Int
    let userPriorityScore: Int?
    let priorityReason: String
    let surfacedAt: Date
    let linkedEventIDs: [UUID]
    let completionEvidence: FollowUpCompletionEvidence?
    let evidenceHint: String?
    let manuallyEditedFields: Set<FollowUpEditableField>
    let history: [FollowUpHistoryEntry]
}

struct FollowUpMergeSelection: Sendable {
    let commitments: [Commitment]
    let sourceIDs: [UUID]
}

/// Resolves fields that must survive an AI-written merge. This helper only
/// returns value types; the caller remains responsible for one atomic save.
enum FollowUpMergeResolver {
    static func confirmationWarning(
        for draft: FollowUpMergeDraft,
        selection: FollowUpMergeSelection,
        targetID: UUID
    ) -> PendingFollowUpMergeConfirmation? {
        guard draft.relationship == .unrelated else { return nil }
        return PendingFollowUpMergeConfirmation(
            sourceIDs: selection.sourceIDs,
            targetID: targetID,
            sourceActions: selection.commitments.map(\.action),
            reason: draft.relationshipReason.isEmpty
                ? "Iriz could not find a clear connection between these follow-ups."
                : draft.relationshipReason,
            draft: draft
        )
    }

    static func activeSelection(ids: [UUID], from commitments: [Commitment]) -> FollowUpMergeSelection {
        let byID = Dictionary(commitments.map { ($0.id, $0) }) { lhs, rhs in
            lhs.updatedAt >= rhs.updatedAt ? lhs : rhs
        }
        var seen = Set<UUID>()
        let selected = ids.compactMap { id -> Commitment? in
            guard seen.insert(id).inserted,
                  let commitment = byID[id],
                  commitment.lifecycle == .active else { return nil }
            return commitment
        }
        return FollowUpMergeSelection(
            commitments: selected,
            sourceIDs: selected.map(\.id)
        )
    }

    static func applyingAIContent(
        _ draft: FollowUpMergeDraft,
        to target: Commitment,
        preserving sources: [Commitment] = []
    ) -> Commitment {
        var merged = target
        if !target.manuallyEditedFields.contains(.action) {
            merged.action = draft.action.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !target.manuallyEditedFields.contains(.summary) { merged.summary = draft.summary }
        if !target.manuallyEditedFields.contains(.details) { merged.details = draft.details }
        merged.rationale = draft.priorityReason
        merged.confidence = draft.confidence
        if let sourceContext = preservedSourceContext(from: sources) {
            merged.details = [merged.details, sourceContext]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            merged.manuallyEditedFields.insert(.details)
        }
        return merged
    }

    static func mergedFields(from commitments: [Commitment]) -> FollowUpMergeFields? {
        let commitments = uniquelyIdentified(commitments)
        guard let first = commitments.first else { return nil }

        let due = selectedDue(from: commitments)
        let priority = selectedPriority(from: commitments)
        let evidence = selectedCompletionEvidence(from: commitments)
        let evidenceHints = Set(commitments.compactMap { commitment -> String? in
            let value = commitment.evidenceHint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        })
        let historyByID = commitments
            .flatMap(\.history)
            .reduce(into: [UUID: FollowUpHistoryEntry]()) { entries, entry in
                entries[entry.id] = entries[entry.id] ?? entry
            }

        return FollowUpMergeFields(
            explicitDueAt: due?.date,
            suggestedReviewAt: nil,
            dueSource: due?.source,
            dueConfidence: due?.confidence,
            aiPriorityScore: priority.aiScore,
            displayPriorityScore: priority.displayScore,
            userPriorityScore: priority.userScore,
            priorityReason: priority.reason,
            surfacedAt: commitments.map(\.surfacedAt).max() ?? first.surfacedAt,
            linkedEventIDs: Array(Set(commitments.flatMap { [$0.eventID] + $0.linkedEventIDs }))
                .sorted { $0.uuidString < $1.uuidString },
            completionEvidence: evidence,
            evidenceHint: evidenceHints.isEmpty ? nil : evidenceHints.sorted().joined(separator: "\n"),
            manuallyEditedFields: commitments.reduce(into: Set<FollowUpEditableField>()) {
                $0.formUnion($1.manuallyEditedFields)
            },
            history: historyByID.values.sorted(by: historyOrder)
        )
    }

    static func applyingMergedFields(
        to target: Commitment,
        sources: [Commitment],
        now: Date = Date()
    ) -> Commitment {
        let all = uniquelyIdentified([target] + sources)
        guard let fields = mergedFields(from: all) else { return target }
        var merged = target
        merged.explicitDueAt = fields.explicitDueAt
        merged.suggestedReviewAt = nil
        merged.dueSource = fields.dueSource
        merged.dueConfidence = fields.dueConfidence
        merged.aiPriorityScore = fields.aiPriorityScore
        merged.displayPriorityScore = fields.displayPriorityScore
        merged.userPriorityScore = fields.userPriorityScore
        merged.priorityReason = fields.priorityReason
        merged.surfacedAt = fields.surfacedAt
        merged.linkedEventIDs = fields.linkedEventIDs
        merged.completionEvidence = fields.completionEvidence
        merged.evidenceHint = fields.evidenceHint
        merged.manuallyEditedFields = fields.manuallyEditedFields
        merged.history = fields.history
        merged.updatedAt = now

        let titles = all.map(\.action)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
            .joined(separator: "; ")
        merged.history.append(FollowUpHistoryEntry(
            kind: .merged,
            actor: .iriz,
            summary: "Merged \(all.count) follow-ups: \(titles)",
            occurredAt: now
        ))
        return merged
    }

    private struct DueCandidate {
        let date: Date
        let source: FollowUpDueSource
        let confidence: Double?
        let rank: Int
        let commitmentID: UUID

    }

    private struct PrioritySelection {
        let aiScore: Int
        let displayScore: Int
        let userScore: Int?
        let reason: String
    }

    private static func selectedDue(from commitments: [Commitment]) -> DueCandidate? {
        commitments.compactMap { commitment -> DueCandidate? in
            guard let date = commitment.explicitDueAt else { return nil }
            let isManual = commitment.manuallyEditedFields.contains(.dueDate)
                || commitment.dueSource == .user
            let source: FollowUpDueSource
            let rank: Int
            if isManual {
                source = .user
                rank = 0
            } else if commitment.dueSource == .explicitEvidence || commitment.explicitDueAt != nil {
                source = .explicitEvidence
                rank = 1
            } else { return nil }
            return DueCandidate(
                date: date,
                source: source,
                confidence: commitment.dueConfidence,
                rank: rank,
                commitmentID: commitment.id
            )
        }
        .min { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            if lhs.confidence != rhs.confidence { return (lhs.confidence ?? 0) > (rhs.confidence ?? 0) }
            return lhs.commitmentID.uuidString < rhs.commitmentID.uuidString
        }
    }

    private static func selectedPriority(from commitments: [Commitment]) -> PrioritySelection {
        let ordered = commitments.sorted { $0.id.uuidString < $1.id.uuidString }
        if let manual = ordered
            .filter({ $0.userPriorityScore != nil })
            .max(by: { lhs, rhs in
                if lhs.userPriorityScore != rhs.userPriorityScore {
                    return (lhs.userPriorityScore ?? 0) < (rhs.userPriorityScore ?? 0)
                }
                return lhs.id.uuidString > rhs.id.uuidString
            }) {
            return PrioritySelection(
                aiScore: manual.aiPriorityScore,
                displayScore: manual.displayPriorityScore,
                userScore: manual.userPriorityScore,
                reason: manual.priorityReason
            )
        }
        let automatic = ordered.max { lhs, rhs in
            if lhs.aiPriorityScore != rhs.aiPriorityScore { return lhs.aiPriorityScore < rhs.aiPriorityScore }
            return lhs.id.uuidString > rhs.id.uuidString
        } ?? ordered[0]
        return PrioritySelection(
            aiScore: automatic.aiPriorityScore,
            displayScore: automatic.displayPriorityScore,
            userScore: nil,
            reason: automatic.priorityReason
        )
    }

    private static func selectedCompletionEvidence(
        from commitments: [Commitment]
    ) -> FollowUpCompletionEvidence? {
        commitments.compactMap(\.completionEvidence).max { lhs, rhs in
            let leftStrength = evidenceRank(lhs.strength)
            let rightStrength = evidenceRank(rhs.strength)
            if leftStrength != rightStrength { return leftStrength < rightStrength }
            if lhs.confidence != rhs.confidence { return lhs.confidence < rhs.confidence }
            if lhs.capturedAt != rhs.capturedAt { return lhs.capturedAt < rhs.capturedAt }
            return lhs.eventID.uuidString > rhs.eventID.uuidString
        }
    }

    private static func evidenceRank(_ strength: FollowUpEvidenceStrength) -> Int {
        switch strength {
        case .weak: 0
        case .strong: 1
        case .explicit: 2
        }
    }

    private static func uniquelyIdentified(_ commitments: [Commitment]) -> [Commitment] {
        commitments.reduce(into: [UUID: Commitment]()) { result, commitment in
            result[commitment.id] = result[commitment.id] ?? commitment
        }
        .values
        .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private static func preservedSourceContext(from commitments: [Commitment]) -> String? {
        var groups: [String] = []
        for commitment in uniquelyIdentified(commitments) {
            var lines = [
                "Subject: \(commitment.contextLabel ?? "Uncategorized")",
                "Action: \(commitment.action)"
            ]
            let summary = commitment.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            let details = commitment.details.trimmingCharacters(in: .whitespacesAndNewlines)
            let owner = commitment.owner.trimmingCharacters(in: .whitespacesAndNewlines)
            if !summary.isEmpty { lines.append("Summary: \(summary)") }
            if !details.isEmpty { lines.append("Details: \(details)") }
            if !owner.isEmpty { lines.append("Owner: \(owner)") }
            groups.append(lines.joined(separator: "\n"))
        }
        guard !groups.isEmpty else { return nil }
        return (["Merged source follow-ups:"] + groups).joined(separator: "\n\n")
    }

    private static func historyOrder(_ lhs: FollowUpHistoryEntry, _ rhs: FollowUpHistoryEntry) -> Bool {
        if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
