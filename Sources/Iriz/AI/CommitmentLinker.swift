import Foundation

enum CommitmentLinker {
    static func duplicateConfidence(_ lhs: Commitment, _ rhs: Commitment) -> Double {
        let left = tokens(lhs.action)
        let right = tokens(rhs.action)
        guard left.count >= 2, right.count >= 2 else { return 0 }
        let overlap = left.intersection(right)
        let union = left.union(right)
        guard !union.isEmpty else { return 0 }
        let lexical = Double(overlap.count) / Double(union.count)
        let ownerBoost = lhs.owner.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            == rhs.owner.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) ? 0.12 : 0
        return min(lexical + ownerBoost, 1)
    }

    static func mergingDuplicate(
        _ proposed: Commitment,
        into candidates: [Commitment],
        threshold: Double = 0.66
    ) -> Commitment? {
        let rankedCandidates = candidates
            .filter({ $0.state != .completed && $0.state != .dismissed })
            .map({ ($0, duplicateConfidence($0, proposed)) })
            .filter({ $0.1 >= threshold })
        guard var match = rankedCandidates.max(by: { $0.1 < $1.1 })?.0 else { return nil }
        match.explicitDueAt = proposed.explicitDueAt ?? match.explicitDueAt
        if match.explicitDueAt == nil {
            match.suggestedReviewAt = [match.suggestedReviewAt, proposed.suggestedReviewAt]
                .compactMap { $0 }
                .min()
        }
        match.confidence = max(match.confidence, proposed.confidence)
        match.rationale = proposed.rationale.count > match.rationale.count ? proposed.rationale : match.rationale
        if match.contextLabel == nil || match.contextLabel == "General" {
            match.contextLabel = proposed.contextLabel ?? match.contextLabel
        }
        match.state = preferredOpenState(match.state, proposed.state)
        match.linkedEventIDs = Array(Set(match.linkedEventIDs + [proposed.eventID] + proposed.linkedEventIDs))
        match.updatedAt = Date()
        return match
    }

    static func matchConfidence(commitment: Commitment, event: ActivityEvent) -> Double {
        guard event.status == .completed, event.startedAt >= commitment.createdAt else { return 0 }
        let commitmentTokens = tokens(commitment.action)
        guard commitmentTokens.count >= 2 else { return 0 }
        let eventTokens = tokens(event.searchableText)
        let overlap = commitmentTokens.intersection(eventTokens)
        let coverage = Double(overlap.count) / Double(commitmentTokens.count)
        let identityBoost = commitmentTokens.filter { token in
            token.count >= 5 && eventTokens.contains(token)
        }.isEmpty ? 0 : 0.12
        return min(coverage + identityBoost, 1)
    }

    static func linking(
        _ commitment: Commitment,
        to event: ActivityEvent,
        suggestionThreshold: Double = 0.62,
        automaticCompletionThreshold: Double = 0.90
    ) -> Commitment? {
        let confidence = matchConfidence(commitment: commitment, event: event)
        guard confidence >= suggestionThreshold else { return nil }
        var updated = commitment
        updated.linkedEventIDs = Array(Set(updated.linkedEventIDs + [event.id]))
        let completesAutomatically = confidence >= automaticCompletionThreshold
        updated.state = completesAutomatically ? .completed : .completionSuggested
        updated.confidence = max(updated.confidence, confidence)
        let evidenceLabel = completesAutomatically ? "Automatically completed from matching evidence" : "Possible completion evidence"
        updated.rationale = [updated.rationale, "\(evidenceLabel): \(event.title) at \(event.startedAt.formatted(date: .abbreviated, time: .shortened))."]
            .filter { !$0.isEmpty }.joined(separator: " ")
        updated.updatedAt = Date()
        return updated
    }

    private static func preferredOpenState(_ lhs: CommitmentState, _ rhs: CommitmentState) -> CommitmentState {
        let order: [CommitmentState: Int] = [.completionSuggested: 5, .needsAttention: 4, .waiting: 3, .later: 2, .maybe: 1]
        return (order[lhs] ?? 0) >= (order[rhs] ?? 0) ? lhs : rhs
    }

    private static func tokens(_ text: String) -> Set<String> {
        let stop = Set(["the", "and", "for", "with", "this", "that", "from", "you", "your", "send", "sent", "share", "shared", "follow", "faire", "avec", "pour", "dans", "envoyer", "envoye", "envoyé", "partager"])
        return Set(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 && !stop.contains($0) })
    }
}
