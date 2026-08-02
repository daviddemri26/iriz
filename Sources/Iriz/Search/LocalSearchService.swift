import Foundation
import NaturalLanguage

actor LocalSearchService {
    private let repository: any LogRepository

    init(repository: any LogRepository) {
        self.repository = repository
    }

    func candidates(for question: String, limit: Int = 12) async throws -> [ActivityEvent] {
        let filters = QueryUnderstanding.parse(question)
        var candidates = try await repository.searchEvents(query: filters.searchText, limit: max(limit * 3, 30))
        if candidates.isEmpty {
            candidates = try await repository.events(limit: 200, importantOnly: false)
        }
        if let interval = filters.dateInterval {
            candidates = candidates.filter { interval.contains($0.startedAt) }
        }
        return SemanticRanker.rank(question: question, events: candidates).prefix(limit).map { $0 }
    }
}

struct QueryUnderstanding: Equatable {
    var searchText: String
    var dateInterval: DateInterval?

    static func parse(_ question: String, now: Date = Date(), calendar: Calendar = .current) -> QueryUnderstanding {
        let normalized = question.lowercased()
        var interval: DateInterval?
        if normalized.contains("today") || normalized.contains("aujourd'hui") {
            let start = calendar.startOfDay(for: now)
            interval = DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start) ?? now)
        } else if normalized.contains("yesterday") || normalized.contains("hier") {
            let today = calendar.startOfDay(for: now)
            let start = calendar.date(byAdding: .day, value: -1, to: today) ?? today
            interval = DateInterval(start: start, end: today)
        } else if let days = relativeDays(in: normalized) {
            let start = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)) ?? now
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? now
            interval = DateInterval(start: start, end: end)
        }
        let stopWords = Set(["what", "where", "when", "which", "who", "did", "was", "were", "the", "a", "an", "i", "me", "my", "you", "can", "find", "show", "tell", "quel", "quelle", "ou", "où", "quand", "est", "etait", "était", "je", "j'ai", "moi", "mon", "ma", "mes", "peux", "retrouver", "montre", "il", "y", "a", "days", "day", "jours", "jour", "ago"])
        let terms = normalized.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 2 && !stopWords.contains($0) }
        return QueryUnderstanding(searchText: terms.joined(separator: " "), dateInterval: interval)
    }

    private static func relativeDays(in text: String) -> Int? {
        let patterns = [
            #"(\d+)\s+days?\s+ago"#,
            #"il\s+y\s+a\s+(\d+)\s+jours?"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text),
                  let days = Int(text[range]) else { continue }
            return max(days, 1)
        }
        return nil
    }
}

enum SemanticRanker {
    static func rank(question: String, events: [ActivityEvent]) -> [ActivityEvent] {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english),
              let queryVector = embedding.vector(for: question) else {
            return lexicalRank(question: question, events: events)
        }
        return events.sorted {
            score(event: $0, query: question, vector: queryVector, embedding: embedding) >
            score(event: $1, query: question, vector: queryVector, embedding: embedding)
        }
    }

    private static func score(event: ActivityEvent, query: String, vector: [Double], embedding: NLEmbedding) -> Double {
        let semantic: Double
        if let candidate = embedding.vector(for: String(event.searchableText.prefix(1_000))) {
            semantic = cosine(vector, candidate)
        } else {
            semantic = 0
        }
        let tokens = Set(query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        let haystack = event.searchableText.lowercased()
        let lexical = tokens.isEmpty ? 0 : Double(tokens.filter(haystack.contains).count) / Double(tokens.count)
        let importance = Double(event.importance.rawValue) / 10
        return semantic * 0.65 + lexical * 0.3 + importance * 0.05
    }

    private static func cosine(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot = 0.0
        var left = 0.0
        var right = 0.0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            left += lhs[index] * lhs[index]
            right += rhs[index] * rhs[index]
        }
        let denominator = sqrt(left) * sqrt(right)
        return denominator > 0 ? dot / denominator : 0
    }

    private static func lexicalRank(question: String, events: [ActivityEvent]) -> [ActivityEvent] {
        let tokens = Set(question.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        return events.sorted {
            let left = tokens.filter($0.searchableText.lowercased().contains).count
            let right = tokens.filter($1.searchableText.lowercased().contains).count
            return left == right ? $0.startedAt > $1.startedAt : left > right
        }
    }
}
