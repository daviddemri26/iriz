import Foundation

enum CommitmentLinker {
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

    static func linking(_ commitment: Commitment, to event: ActivityEvent, threshold: Double = 0.72) -> Commitment? {
        let confidence = matchConfidence(commitment: commitment, event: event)
        guard confidence >= threshold else { return nil }
        var updated = commitment
        updated.linkedEventIDs = Array(Set(updated.linkedEventIDs + [event.id]))
        updated.state = .completed
        updated.confidence = max(updated.confidence, confidence)
        updated.rationale = [updated.rationale, "Matching evidence: \(event.title) at \(event.startedAt.formatted(date: .abbreviated, time: .shortened))."]
            .filter { !$0.isEmpty }.joined(separator: " ")
        updated.updatedAt = Date()
        return updated
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
