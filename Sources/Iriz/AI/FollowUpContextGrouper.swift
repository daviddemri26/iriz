import Foundation

struct FollowUpContextGroup: Identifiable, Sendable {
    let id: String
    let label: String
    let commitmentIDs: Set<UUID>

    var count: Int { commitmentIDs.count }
}

enum FollowUpContextGrouper {
    static let maximumVisibleGroups = 8

    static func groups(
        commitments: [RankedCommitment],
        events: [ActivityEvent],
        maximumGroups: Int = maximumVisibleGroups
    ) -> [FollowUpContextGroup] {
        guard maximumGroups > 0 else { return [] }
        let eventsByID = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        var buckets: [String: (label: String, ids: Set<UUID>)] = [:]

        for ranked in commitments {
            let commitment = ranked.commitment
            let label = label(for: commitment, event: eventsByID[commitment.eventID])
            let id = identifier(for: label)
            var bucket = buckets[id] ?? (label, [])
            bucket.ids.insert(commitment.id)
            buckets[id] = bucket
        }

        let sorted = buckets.map { FollowUpContextGroup(id: $0.key, label: $0.value.label, commitmentIDs: $0.value.ids) }
            .sorted(by: contextOrder)
        guard sorted.count > maximumGroups else { return sorted }

        let keptCount = max(0, maximumGroups - 1)
        let kept = Array(sorted.prefix(keptCount))
        let overflowIDs = sorted.dropFirst(keptCount).reduce(into: Set<UUID>()) { result, group in
            result.formUnion(group.commitmentIDs)
        }
        return kept + [FollowUpContextGroup(id: "other", label: "Other", commitmentIDs: overflowIDs)]
    }

    static func contextLabels(from commitments: [Commitment], limit: Int = 12) -> [String] {
        Array(Set(commitments.compactMap { canonicalLabel($0.contextLabel) }))
            .filter { $0 != "General" }
            .sorted { lhs, rhs in
                let leftPriority = priority(for: lhs)
                let rightPriority = priority(for: rhs)
                return leftPriority == rightPriority
                    ? lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
                    : leftPriority < rightPriority
            }
            .prefix(limit)
            .map { $0 }
    }

    static func canonicalLabel(_ rawLabel: String?) -> String? {
        guard let rawLabel else { return nil }
        let trimmed = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let folded = foldedText(trimmed)

        if workAliases.contains(folded) { return "Work" }
        if personalAliases.contains(folded) { return "Personal" }
        if familyAliases.contains(folded) { return "Family" }
        if travelAliases.contains(folded) { return "Travel" }
        if generalAliases.contains(folded) { return "General" }
        return String(trimmed.prefix(42))
    }

    static func label(for commitment: Commitment, event: ActivityEvent?) -> String {
        if let explicit = canonicalLabel(commitment.contextLabel), explicit != "General" {
            return explicit
        }

        let searchable = foldedText([
            commitment.action,
            commitment.rationale,
            event?.searchableText ?? ""
        ].joined(separator: " "))
        if travelKeywords.contains(where: searchable.contains) { return "Travel" }

        switch event?.kind {
        case .application, .meeting, .document:
            return "Work"
        case .purchase, .appointment:
            return "Personal"
        default:
            return canonicalLabel(commitment.contextLabel) ?? "General"
        }
    }

    private static func contextOrder(_ lhs: FollowUpContextGroup, _ rhs: FollowUpContextGroup) -> Bool {
        let leftPriority = priority(for: lhs.label)
        let rightPriority = priority(for: rhs.label)
        if leftPriority != rightPriority { return leftPriority < rightPriority }
        if lhs.count != rhs.count { return lhs.count > rhs.count }
        return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
    }

    private static func priority(for label: String) -> Int {
        switch label {
        case "Work": 0
        case "Personal": 1
        case "Family": 2
        case "Travel": 3
        case "General": 90
        case "Other": 100
        default: 10
        }
    }

    private static func identifier(for label: String) -> String {
        let words = foldedText(label).split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return words.isEmpty ? "general" : words.joined(separator: "-")
    }

    private static func foldedText(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    private static let workAliases: Set<String> = [
        "work", "professional", "business", "job", "travail", "professionnel", "trabajo", "arbeit", "lavoro", "trabalho", "עבודה"
    ]
    private static let personalAliases: Set<String> = [
        "personal", "home", "private", "personnel", "perso", "casa", "privat", "personale", "pessoal", "אישי"
    ]
    private static let familyAliases: Set<String> = [
        "family", "famille", "familia", "familie", "famiglia", "família", "משפחה"
    ]
    private static let travelAliases: Set<String> = [
        "travel", "vacation", "holiday", "trip", "voyage", "vacances", "viaje", "urlaub", "reise", "viaggio", "viagem", "נסיעות", "חופשה"
    ]
    private static let generalAliases: Set<String> = [
        "general", "other", "misc", "général", "autre", "autres", "otro", "andere", "altro", "outro", "כללי"
    ]
    private static let travelKeywords = [
        "vacation", "holiday", "travel", "trip", "flight", "hotel", "vacances", "voyage", "vol ", "hôtel", "hotel", "viaje", "vuelo", "urlaub", "reise", "flug", "viaggio", "volo", "viagem", "voo", "חופשה", "טיסה", "מלון"
    ]
}
