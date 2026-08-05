import Foundation

enum CommitmentLinker {
    static let maximumRelatedCandidates = 8

    /// Applies text learned from a later observation without allowing the
    /// current creation granularity to rewrite an existing follow-up's scope.
    /// Action and summary remain stable; Iriz may only add non-destructive
    /// detail when that field has not been made authoritative by the user.
    static func applyingNonDestructiveTextUpdate(
        _ draft: CommitmentDraft,
        to commitment: Commitment
    ) -> Commitment {
        var updated = commitment
        guard !commitment.manuallyEditedFields.contains(.details) else { return updated }

        let incoming = draft.details.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !incoming.isEmpty else { return updated }
        let existing = commitment.details.trimmingCharacters(in: .whitespacesAndNewlines)
        guard existing.range(
            of: incoming,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) == nil else { return updated }

        updated.details = existing.isEmpty ? incoming : "\(existing)\n\n\(incoming)"
        return updated
    }

    static func relatedCandidates(
        for proposed: Commitment,
        sourceEvent: ActivityEvent? = nil,
        among candidates: [Commitment],
        events: [ActivityEvent] = [],
        subjects: [FollowUpSubject] = [],
        maximumCount: Int = maximumRelatedCandidates
    ) -> [Commitment] {
        let eventsByID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: newestEvent)
        let queryEvent = sourceEvent ?? eventsByID[proposed.eventID]
        let query = CandidateQuery(
            actionTokens: tokens(proposed.action),
            subjectID: resolvedSubjectID(for: proposed, subjects: subjects),
            eventID: queryEvent?.id ?? proposed.eventID,
            linkedEventIDs: Set(proposed.linkedEventIDs),
            eventTokens: tokens(queryEvent?.searchableText ?? ""),
            entityTokens: entityTokens(queryEvent?.entities ?? [])
        )
        return selectRelatedCandidates(
            query: query,
            candidates: candidates.filter { $0.id != proposed.id },
            eventsByID: eventsByID,
            subjects: subjects,
            maximumCount: maximumCount
        )
    }

    static func relatedCandidates(
        for event: ActivityEvent,
        subject: FollowUpSubject? = nil,
        among candidates: [Commitment],
        events: [ActivityEvent] = [],
        subjects: [FollowUpSubject] = [],
        maximumCount: Int = maximumRelatedCandidates
    ) -> [Commitment] {
        var eventsByID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: newestEvent)
        // The event being reconciled is the authoritative current version.
        eventsByID[event.id] = event
        let query = CandidateQuery(
            actionTokens: tokens(event.searchableText),
            subjectID: subject?.id,
            eventID: event.id,
            linkedEventIDs: [],
            eventTokens: tokens(event.searchableText),
            entityTokens: entityTokens(event.entities)
        )
        return selectRelatedCandidates(
            query: query,
            candidates: candidates,
            eventsByID: eventsByID,
            subjects: subjects,
            maximumCount: maximumCount
        )
    }

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
        match.suggestedReviewAt = nil
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
        let hasExplicitCompletionLanguage = !normalizedWords(event.searchableText)
            .isDisjoint(with: explicitCompletionTokens)
        guard event.startedAt >= commitment.createdAt,
              event.status == .completed || hasExplicitCompletionLanguage else { return 0 }
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
        automaticCompletionThreshold: Double = 0.82,
        now: Date = Date()
    ) -> Commitment? {
        guard commitment.lifecycle == .active || commitment.lifecycle == .snoozed else { return nil }
        let confidence = matchConfidence(commitment: commitment, event: event)
        guard confidence >= suggestionThreshold else { return nil }
        var updated = commitment
        updated.linkedEventIDs = uniqueEventIDs(updated.linkedEventIDs + [event.id])
        let evidence = completionEvidence(
            commitment: commitment,
            event: event,
            confidence: confidence
        )
        let completesAutomatically = confidence >= automaticCompletionThreshold
            && evidence.strength != .weak
        updated.state = completesAutomatically ? .completed : .completionSuggested
        if completesAutomatically {
            updated.lifecycle = .completed
            updated.completedAt = now
            updated.snoozedUntil = nil
            updated.dismissedAt = nil
            updated.completionActor = .iriz
            updated.completionEvidence = evidence
            updated.evidenceHint = nil
        } else {
            // Keep the lifecycle open. The legacy state remains a compatibility
            // signal for older clients, while the new UI presents only the hint.
            updated.lifecycle = commitment.lifecycle
            updated.completionEvidence = evidence
            updated.evidenceHint = evidence.summary
        }
        updated.confidence = max(updated.confidence, confidence)
        let evidenceLabel = completesAutomatically ? "Automatically completed from matching evidence" : "Possible completion evidence"
        updated.rationale = [updated.rationale, "\(evidenceLabel): \(event.title) at \(event.startedAt.formatted(date: .abbreviated, time: .shortened))."]
            .filter { !$0.isEmpty }.joined(separator: " ")
        updated.updatedAt = now
        updated.history.append(FollowUpHistoryEntry(
            kind: .evidence,
            actor: .iriz,
            summary: evidence.summary,
            occurredAt: now,
            eventID: event.id
        ))
        if completesAutomatically {
            updated.history.append(FollowUpHistoryEntry(
                kind: .completed,
                actor: .iriz,
                summary: "Completed from strong matching evidence",
                occurredAt: now,
                eventID: event.id
            ))
        }
        return updated
    }

    static func completionEvidence(
        commitment: Commitment,
        event: ActivityEvent
    ) -> FollowUpCompletionEvidence? {
        let confidence = matchConfidence(commitment: commitment, event: event)
        guard confidence > 0 else { return nil }
        return completionEvidence(commitment: commitment, event: event, confidence: confidence)
    }

    private static func preferredOpenState(_ lhs: CommitmentState, _ rhs: CommitmentState) -> CommitmentState {
        let order: [CommitmentState: Int] = [.completionSuggested: 5, .needsAttention: 4, .waiting: 3, .later: 2, .maybe: 1]
        return (order[lhs] ?? 0) >= (order[rhs] ?? 0) ? lhs : rhs
    }

    private static func newestEvent(_ lhs: ActivityEvent, _ rhs: ActivityEvent) -> ActivityEvent {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt ? lhs : rhs }
        return lhs.endedAt >= rhs.endedAt ? lhs : rhs
    }

    private struct CandidateQuery {
        let actionTokens: Set<String>
        let subjectID: String?
        let eventID: UUID?
        let linkedEventIDs: Set<UUID>
        let eventTokens: Set<String>
        let entityTokens: Set<String>
    }

    private static func selectRelatedCandidates(
        query: CandidateQuery,
        candidates: [Commitment],
        eventsByID: [UUID: ActivityEvent],
        subjects: [FollowUpSubject],
        maximumCount: Int
    ) -> [Commitment] {
        let limit = min(max(maximumCount, 0), maximumRelatedCandidates)
        guard limit > 0 else { return [] }

        return candidates
            .filter { $0.lifecycle == .active || $0.lifecycle == .snoozed }
            .map { candidate -> (Commitment, Double) in
                let candidateEvents = ([candidate.eventID] + candidate.linkedEventIDs)
                    .compactMap { eventsByID[$0] }
                let candidateEventTokens = candidateEvents.reduce(into: Set<String>()) {
                    $0.formUnion(tokens($1.searchableText))
                }
                let candidateEntityTokens = candidateEvents.reduce(into: Set<String>()) {
                    $0.formUnion(entityTokens($1.entities))
                }
                let actionOverlap = overlapCoefficient(query.actionTokens, tokens(candidate.action))
                let eventOverlap = overlapCoefficient(
                    query.eventTokens,
                    candidateEventTokens.isEmpty ? tokens(candidate.action) : candidateEventTokens
                )
                let entityOverlap = overlapCoefficient(query.entityTokens, candidateEntityTokens)
                let candidateSubjectID = resolvedSubjectID(for: candidate, subjects: subjects)
                let subjectOverlap = query.subjectID != nil && query.subjectID == candidateSubjectID ? 1.0 : 0
                let directEventOverlap = query.eventID.map { eventID in
                    candidate.eventID == eventID || candidate.linkedEventIDs.contains(eventID)
                } ?? false
                let linkedOverlap = !query.linkedEventIDs.isDisjoint(with: Set(candidate.linkedEventIDs + [candidate.eventID]))
                let score = actionOverlap * 0.48
                    + subjectOverlap * 0.20
                    + eventOverlap * 0.14
                    + entityOverlap * 0.18
                    + ((directEventOverlap || linkedOverlap) ? 0.45 : 0)
                return (candidate, min(score, 1))
            }
            .filter { $0.1 > 0 }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                if lhs.0.surfacedAt != rhs.0.surfacedAt { return lhs.0.surfacedAt > rhs.0.surfacedAt }
                return lhs.0.id.uuidString < rhs.0.id.uuidString
            }
            .prefix(limit)
            .map(\.0)
    }

    private static func completionEvidence(
        commitment: Commitment,
        event: ActivityEvent,
        confidence: Double
    ) -> FollowUpCompletionEvidence {
        let eventText = normalizedWords(event.searchableText)
        let explicit = !eventText.isDisjoint(with: explicitCompletionTokens)
        let strength: FollowUpEvidenceStrength
        if explicit {
            strength = .explicit
        } else if event.status == .completed && confidence >= 0.70 {
            strength = .strong
        } else {
            strength = .weak
        }
        let detail = event.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = detail.isEmpty ? event.title : "\(event.title) — \(detail)"
        return FollowUpCompletionEvidence(
            eventID: event.id,
            summary: summary,
            confidence: confidence,
            strength: strength,
            capturedAt: event.endedAt
        )
    }

    private static func resolvedSubjectID(
        for commitment: Commitment,
        subjects: [FollowUpSubject]
    ) -> String? {
        if let subjectID = commitment.subjectID { return subjectID }
        return FollowUpContextGrouper.resolveSubject(named: commitment.contextLabel, in: subjects)?.id
            ?? commitment.contextLabel.map(FollowUpSubject.identifier(for:))
    }

    private static func overlapCoefficient(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        return Double(lhs.intersection(rhs).count) / Double(min(lhs.count, rhs.count))
    }

    private static func entityTokens(_ entities: [String]) -> Set<String> {
        entities.reduce(into: Set<String>()) { result, entity in
            result.formUnion(tokens(entity))
        }
    }

    private static func uniqueEventIDs(_ ids: [UUID]) -> [UUID] {
        Array(Set(ids)).sorted { $0.uuidString < $1.uuidString }
    }

    private static func tokens(_ text: String) -> Set<String> {
        let stop = Set(["the", "and", "for", "with", "this", "that", "from", "you", "your", "send", "sent", "share", "shared", "follow", "faire", "avec", "pour", "dans", "envoyer", "envoye", "envoyé", "partager"])
        return normalizedWords(text).filter { !stop.contains($0) }
    }

    private static func normalizedWords(_ text: String) -> Set<String> {
        Set(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 })
    }

    private static let explicitCompletionTokens: Set<String> = [
        "booked", "completed", "confirmed", "delivered", "done", "emailed", "finished", "paid", "resolved", "sent", "shared", "submitted", "uploaded",
        "envoye", "envoyé", "termine", "terminé", "confirme", "confirmé", "livre", "livré", "paye", "payé", "soumis"
    ]
}
