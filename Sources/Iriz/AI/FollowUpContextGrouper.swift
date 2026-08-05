import Foundation

struct FollowUpContextGroup: Identifiable, Sendable {
    let id: String
    let label: String
    let commitmentIDs: Set<UUID>

    var count: Int { commitmentIDs.count }
}

struct FollowUpSubjectResolution: Sendable {
    let subject: FollowUpSubject
    let subjects: [FollowUpSubject]
    let wasCreated: Bool
}

enum FollowUpContextGrouper {
    static let maximumVisibleGroups = 8

    static func groups(
        commitments: [RankedCommitment],
        events: [ActivityEvent],
        maximumGroups: Int = maximumVisibleGroups
    ) -> [FollowUpContextGroup] {
        guard maximumGroups > 0 else { return [] }
        let eventsByID = Dictionary(events.map { ($0.id, $0) }) { lhs, rhs in
            lhs.updatedAt >= rhs.updatedAt ? lhs : rhs
        }
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
            .filter { !isGenericSubjectName($0) }
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

    static func isGenericSubjectName(_ rawLabel: String?) -> Bool {
        guard let label = canonicalLabel(rawLabel) else { return true }
        return genericSubjectLabels.contains(label)
    }

    /// Keeps Work/Personal as an area while deriving a concrete, reusable subject.
    /// Cloud extraction normally supplies the label; this local fallback repairs
    /// older generic subjects without sending personal priority history anywhere.
    static func specificSubjectLabel(
        suggested rawLabel: String?,
        action: String,
        context: String = "",
        event: ActivityEvent? = nil,
        area explicitArea: FollowUpArea? = nil
    ) -> String {
        if let explicit = canonicalLabel(rawLabel), !isGenericSubjectName(explicit) {
            return explicit
        }

        let primaryContext = foldedText([action, context].joined(separator: " "))
        let searchable = foldedText([action, context, event?.searchableText ?? ""].joined(separator: " "))
        let entity = event?.entities
            .filter(isMeaningfulEntity)
            .sorted {
                let leftScore = entityScore($0, primaryContext: primaryContext)
                let rightScore = entityScore($1, primaryContext: primaryContext)
                return leftScore == rightScore
                    ? $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                    : leftScore > rightScore
            }
            .first
        let hostName = event?.urls.first?.host().flatMap(subjectName(fromHost:))

        if websiteKeywords.contains(where: searchable.contains) {
            if let entity { return String("\(entity) Website".prefix(42)) }
            if let hostName { return String("\(hostName) Website".prefix(42)) }
            return "Website Work"
        }
        if childrenKeywords.contains(where: searchable.contains) {
            if let entity { return String("\(entity) Activities".prefix(42)) }
            return "Kids Activities"
        }
        if clientKeywords.contains(where: searchable.contains), let entity {
            return String("Client \(entity)".prefix(42))
        }
        if travelKeywords.contains(where: searchable.contains) {
            if let entity { return String("\(entity) Travel".prefix(42)) }
            return "Travel Planning"
        }
        if let entity { return String(entity.prefix(42)) }
        if let hostName { return String(hostName.prefix(42)) }

        return switch event?.kind {
        case .application: "Applications"
        case .meeting: "Meetings"
        case .document: "Documents"
        case .purchase: "Orders & Purchases"
        case .appointment: "Appointments"
        case .communication: "Correspondence"
        case .research: "Research"
        case .decision: "Decisions"
        case .task, .note, .context, .other, nil:
            switch explicitArea ?? FollowUpArea.inferred(from: rawLabel) {
            case .work: "Work Projects"
            case .personal: "Personal Errands"
            case .uncategorized: "Uncategorized"
            }
        }
    }

    static func resolveSubject(
        named rawLabel: String?,
        in subjects: [FollowUpSubject]
    ) -> FollowUpSubject? {
        guard let rawLabel,
              !rawLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return subjects.first(where: { $0.id == "uncategorized" })
        }

        let normalized = subjectLookupKey(rawLabel)
        let identifier = FollowUpSubject.identifier(for: rawLabel)
        return subjects.first(where: { $0.id == identifier })
            ?? subjects.first(where: { subjectLookupKey($0.name) == normalized })
            ?? subjects.first(where: { subject in
                subject.aliases.contains(where: { subjectLookupKey($0) == normalized })
            })
    }

    static func resolveSubject(
        for commitment: Commitment,
        event: ActivityEvent?,
        in subjects: [FollowUpSubject]
    ) -> FollowUpSubject? {
        if let subjectID = commitment.subjectID,
           let exact = subjects.first(where: { $0.id == subjectID }) {
            return exact
        }
        if commitment.contextLabel != nil,
           let contextMatch = resolveSubject(named: commitment.contextLabel, in: subjects) {
            return contextMatch
        }
        return resolveSubject(named: label(for: commitment, event: event), in: subjects)
    }

    static func resolveOrCreateSubject(
        named rawLabel: String?,
        area explicitArea: FollowUpArea? = nil,
        in subjects: [FollowUpSubject],
        now: Date = Date()
    ) -> FollowUpSubjectResolution {
        let canonical = canonicalLabel(rawLabel)
        let label = canonical.map { isGenericSubjectName($0) ? "Uncategorized" : $0 } ?? "Uncategorized"
        if let resolved = resolveSubject(named: label, in: subjects) {
            return FollowUpSubjectResolution(subject: resolved, subjects: subjects, wasCreated: false)
        }

        let subject = FollowUpSubject(
            name: label,
            area: explicitArea ?? FollowUpArea.inferred(from: label),
            createdAt: now,
            updatedAt: now
        )
        return FollowUpSubjectResolution(
            subject: subject,
            subjects: subjects + [subject],
            wasCreated: true
        )
    }

    static func resolveOrCreateSubject(
        for commitment: Commitment,
        event: ActivityEvent?,
        in subjects: [FollowUpSubject],
        now: Date = Date()
    ) -> FollowUpSubjectResolution {
        if let subjectID = commitment.subjectID,
           let exact = subjects.first(where: { $0.id == subjectID }),
           commitment.manuallyEditedFields.contains(.subject) || !isGenericSubjectName(exact.name) {
            return FollowUpSubjectResolution(subject: exact, subjects: subjects, wasCreated: false)
        }
        let proposedLabel = label(for: commitment, event: event)
        return resolveOrCreateSubject(
            named: proposedLabel,
            area: commitment.area,
            in: subjects,
            now: now
        )
    }

    static func label(for commitment: Commitment, event: ActivityEvent?) -> String {
        specificSubjectLabel(
            suggested: commitment.contextLabel,
            action: commitment.action,
            context: commitment.rationale,
            event: event,
            area: commitment.area
        )
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

    private static func subjectLookupKey(_ value: String) -> String {
        foldedText(value)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }

    private static func foldedText(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    private static func isMeaningfulEntity(_ value: String) -> Bool {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.count >= 3
            && clean.count <= 60
            && !isGenericSubjectName(clean)
            && !ignoredEntityLabels.contains(foldedText(clean))
    }

    private static func entityScore(_ value: String, primaryContext: String) -> Int {
        let folded = foldedText(value)
        var score = primaryContext.contains(folded) ? 4 : 0
        if value.split(separator: " ").count > 1 { score += 2 }
        let tokens = Set(folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        if !tokens.isDisjoint(with: organizationKeywords) { score += 4 }
        return score
    }

    private static func subjectName(fromHost host: String) -> String? {
        let labels = host.lowercased().split(separator: ".")
        guard let raw = labels.first(where: { $0 != "www" && $0 != "app" }) else { return nil }
        return raw
            .split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
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
    private static let genericSubjectLabels: Set<String> = [
        "Work", "Personal", "Family", "Travel", "General", "Other", "Uncategorized"
    ]
    private static let websiteKeywords = [
        "website", "web site", "site web", "landing page", "homepage", "about page", "page about"
    ]
    private static let childrenKeywords = [
        "children", "child ", "kids", "kid ", "school", "daycare", "enfants", "enfant ", "école", "ecole", "crèche", "creche"
    ]
    private static let clientKeywords = [
        "client", "customer", "account", "prospect"
    ]
    private static let travelKeywords = [
        "vacation", "holiday", "travel", "trip", "flight", "hotel", "vacances", "voyage", "vol ", "hôtel", "hotel", "viaje", "vuelo", "urlaub", "reise", "flug", "viaggio", "volo", "viagem", "voo", "חופשה", "טיסה", "מלון"
    ]
    private static let organizationKeywords: Set<String> = [
        "client", "company", "consulting", "studio", "agency", "group", "inc", "llc", "ltd", "corp"
    ]
    private static let ignoredEntityLabels: Set<String> = [
        "website", "site", "project", "task", "follow up", "email", "document", "application", "meeting", "user",
        "school", "children", "child", "kids"
    ]
}
