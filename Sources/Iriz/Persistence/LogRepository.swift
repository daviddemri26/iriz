import Foundation

protocol LogRepository: Sendable {
    func saveObservation(_ observation: Observation) async throws
    func markObservationProcessed(id: UUID, at date: Date) async throws
    func observation(id: UUID) async throws -> Observation?
    func pendingObservations(limit: Int) async throws -> [Observation]
    func saveEvent(_ event: ActivityEvent) async throws
    func event(id: UUID) async throws -> ActivityEvent?
    func events(limit: Int, importantOnly: Bool) async throws -> [ActivityEvent]
    func searchEvents(query: String, limit: Int) async throws -> [ActivityEvent]
    func deleteEvent(id: UUID) async throws
    func saveCommitment(_ commitment: Commitment) async throws
    func commitments(includingClosed: Bool) async throws -> [Commitment]
    func purgeExpired(now: Date, retention: StructuredRetention) async throws
    func eventCount() async throws -> Int
}

enum SearchQuery {
    static func ftsExpression(for input: String) -> String? {
        let tokens = input
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 2 }
            .prefix(12)
        guard !tokens.isEmpty else { return nil }
        return tokens
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
            .joined(separator: " OR ")
    }
}
