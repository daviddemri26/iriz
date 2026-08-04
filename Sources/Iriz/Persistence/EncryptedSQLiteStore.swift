import CryptoKit
import Foundation
import SQLite3

enum SQLiteStoreError: LocalizedError {
    case openFailed(String)
    case sqlite(code: Int32, message: String, sql: String?)
    case serializationFailed
    case invalidStoredData

    var errorDescription: String? {
        switch self {
        case .openFailed(let message): "Unable to open the local journal: \(message)"
        case .sqlite(let code, let message, let sql):
            "SQLite error \(code): \(message)\(sql.map { " while running \($0)" } ?? "")"
        case .serializationFailed: "The local journal could not be encrypted."
        case .invalidStoredData: "The encrypted journal could not be decoded."
        }
    }
}

private enum SQLiteBoundValue {
    case text(String)
    case int(Int64)
    case double(Double)
    case blob(Data)
    case null
}

actor EncryptedSQLiteStore: LogRepository {
    nonisolated(unsafe) private var database: OpaquePointer?
    private let databaseFile: URL
    private let crypto: CryptoBox
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(directory: URL? = nil, keyData: Data? = nil) throws {
        let root = try directory ?? ApplicationDirectories.applicationSupport()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.databaseFile = root.appendingPathComponent("Iriz.sqlite.iriz")
        self.crypto = try CryptoBox(keyData: try keyData ?? SecurityBootstrap.keyData(account: KeychainAccounts.databaseKey))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder

        var connection: OpaquePointer?
        let code = sqlite3_open_v2(
            ":memory:",
            &connection,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard code == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            if let connection { sqlite3_close(connection) }
            throw SQLiteStoreError.openFailed(message)
        }
        self.database = connection

        do {
            if FileManager.default.fileExists(atPath: databaseFile.path) {
                try Self.loadEncryptedDatabase(from: databaseFile, into: connection, crypto: crypto)
            }
            try Self.execute(Self.schemaSQL, on: connection)
        } catch {
            sqlite3_close(connection)
            self.database = nil
            throw error
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    func saveObservation(_ observation: Observation) async throws {
        let payload = try encoder.encode(observation)
        try execute(
            """
            INSERT INTO observations (id, captured_at, expires_at, source, processed_at, payload)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                captured_at = excluded.captured_at,
                expires_at = excluded.expires_at,
                source = excluded.source,
                processed_at = excluded.processed_at,
                payload = excluded.payload
            """,
            [
                .text(observation.id.uuidString),
                .double(observation.capturedAt.timeIntervalSince1970),
                .double(observation.expiresAt.timeIntervalSince1970),
                .text(observation.source.rawValue),
                observation.processedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                .blob(payload)
            ]
        )
        try persist()
    }

    func markObservationProcessed(id: UUID, at date: Date) async throws {
        guard var value = try fetchObservation(id: id) else { return }
        value.processedAt = date
        try await saveObservation(value)
    }

    func observation(id: UUID) async throws -> Observation? {
        try fetchObservation(id: id)
    }

    func pendingObservations(limit: Int) async throws -> [Observation] {
        let statement = try prepare(
            "SELECT payload FROM observations WHERE processed_at IS NULL AND expires_at > ? ORDER BY captured_at ASC LIMIT ?"
        )
        defer { sqlite3_finalize(statement) }
        try bind([.double(Date().timeIntervalSince1970), .int(Int64(limit))], to: statement)
        var values: [Observation] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let data = blob(at: 0, statement: statement),
               let observation = try? decoder.decode(Observation.self, from: data) {
                values.append(observation)
            }
        }
        return values
    }

    func saveEvent(_ event: ActivityEvent) async throws {
        let payload = try encoder.encode(event)
        try transaction {
            try execute(
                """
                INSERT INTO events (id, started_at, ended_at, importance, status, kind, language, payload)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    started_at = excluded.started_at,
                    ended_at = excluded.ended_at,
                    importance = excluded.importance,
                    status = excluded.status,
                    kind = excluded.kind,
                    language = excluded.language,
                    payload = excluded.payload
                """,
                [
                    .text(event.id.uuidString),
                    .double(event.startedAt.timeIntervalSince1970),
                    .double(event.endedAt.timeIntervalSince1970),
                    .int(Int64(event.importance.rawValue)),
                    .text(event.status.rawValue),
                    .text(event.kind.rawValue),
                    .text(event.languageTag),
                    .blob(payload)
                ]
            )
            try execute("DELETE FROM event_fts WHERE id = ?", [.text(event.id.uuidString)])
            try execute(
                "INSERT INTO event_fts (id, title, summary, details, entities, urls, applications) VALUES (?, ?, ?, ?, ?, ?, ?)",
                [
                    .text(event.id.uuidString),
                    .text(event.title),
                    .text(event.summary),
                    .text(event.details),
                    .text(event.entities.joined(separator: " ")),
                    .text(event.urls.map(\.absoluteString).joined(separator: " ")),
                    .text(event.sourceApplications.joined(separator: " "))
                ]
            )
        }
        try persist()
    }

    func event(id: UUID) async throws -> ActivityEvent? {
        try fetchEvent(id: id)
    }

    func events(limit: Int = 500, importantOnly: Bool = false) async throws -> [ActivityEvent] {
        let sql: String
        let arguments: [SQLiteBoundValue]
        if importantOnly {
            sql = "SELECT payload FROM events WHERE importance >= ? ORDER BY started_at DESC LIMIT ?"
            arguments = [.int(Int64(EventImportance.important.rawValue)), .int(Int64(limit))]
        } else {
            sql = "SELECT payload FROM events ORDER BY started_at DESC LIMIT ?"
            arguments = [.int(Int64(limit))]
        }
        return try fetchEvents(sql: sql, arguments: arguments)
    }

    func searchEvents(query: String, limit: Int = 30) async throws -> [ActivityEvent] {
        guard let expression = SearchQuery.ftsExpression(for: query) else {
            return try await events(limit: limit, importantOnly: false)
        }
        let statement = try prepare(
            "SELECT id FROM event_fts WHERE event_fts MATCH ? ORDER BY bm25(event_fts) LIMIT ?"
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(expression), .int(Int64(limit))], to: statement)
        var results: [ActivityEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = string(at: 0, statement: statement),
                  let id = UUID(uuidString: idText),
                  let event = try fetchEvent(id: id) else { continue }
            results.append(event)
        }
        return results
    }

    func deleteEvent(id: UUID) async throws {
        try transaction {
            try execute("DELETE FROM event_fts WHERE id = ?", [.text(id.uuidString)])
            try execute("DELETE FROM events WHERE id = ?", [.text(id.uuidString)])
        }
        try persist()
    }

    func saveCommitment(_ commitment: Commitment) async throws {
        let payload = try encoder.encode(commitment)
        let reviewAt = commitment.explicitDueAt ?? commitment.suggestedReviewAt
        try execute(
            """
            INSERT INTO commitments (id, event_id, state, review_at, confidence, payload)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                event_id = excluded.event_id,
                state = excluded.state,
                review_at = excluded.review_at,
                confidence = excluded.confidence,
                payload = excluded.payload
            """,
            [
                .text(commitment.id.uuidString),
                .text(commitment.eventID.uuidString),
                .text(commitment.state.rawValue),
                reviewAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                .double(commitment.confidence),
                .blob(payload)
            ]
        )
        try persist()
    }

    func commitments(includingClosed: Bool = false) async throws -> [Commitment] {
        let sql: String
        if includingClosed {
            sql = "SELECT payload FROM commitments ORDER BY COALESCE(review_at, 9999999999) ASC"
        } else {
            sql = "SELECT payload FROM commitments WHERE state NOT IN ('completed', 'dismissed') ORDER BY COALESCE(review_at, 9999999999) ASC"
        }
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var values: [Commitment] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let data = blob(at: 0, statement: statement),
               let commitment = try? decoder.decode(Commitment.self, from: data) {
                values.append(commitment)
            }
        }
        return values
    }

    func saveAssistantConversation(_ conversation: AssistantConversation) async throws {
        let payload = try encoder.encode(conversation)
        try execute(
            """
            INSERT INTO assistant_conversations (id, updated_at, payload)
            VALUES (?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                updated_at = excluded.updated_at,
                payload = excluded.payload
            """,
            [
                .text(conversation.id.uuidString),
                .double(conversation.updatedAt.timeIntervalSince1970),
                .blob(payload)
            ]
        )
        try persist()
    }

    func assistantConversations(limit: Int = 100) async throws -> [AssistantConversation] {
        let statement = try prepare(
            "SELECT payload FROM assistant_conversations ORDER BY updated_at DESC LIMIT ?"
        )
        defer { sqlite3_finalize(statement) }
        try bind([.int(Int64(limit))], to: statement)
        var values: [AssistantConversation] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let data = blob(at: 0, statement: statement),
               let conversation = try? decoder.decode(AssistantConversation.self, from: data) {
                values.append(conversation)
            }
        }
        return values
    }

    func deleteAssistantConversation(id: UUID) async throws {
        try execute("DELETE FROM assistant_conversations WHERE id = ?", [.text(id.uuidString)])
        try persist()
    }

    func purgeExpired(now: Date = Date(), retention: StructuredRetention) async throws {
        try transaction {
            try execute("DELETE FROM observations WHERE expires_at <= ?", [.double(now.timeIntervalSince1970)])
            if let interval = retention.cutoffInterval {
                let cutoff = now.addingTimeInterval(-interval).timeIntervalSince1970
                let ids = try stringColumn(sql: "SELECT id FROM events WHERE ended_at < ?", arguments: [.double(cutoff)])
                for id in ids {
                    try execute("DELETE FROM event_fts WHERE id = ?", [.text(id)])
                }
                try execute("DELETE FROM events WHERE ended_at < ?", [.double(cutoff)])
            }
        }
        try persist()
    }

    func eventCount() async throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM events")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func fetchObservation(id: UUID) throws -> Observation? {
        let statement = try prepare("SELECT payload FROM observations WHERE id = ? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        try bind([.text(id.uuidString)], to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let data = blob(at: 0, statement: statement) else { return nil }
        return try decoder.decode(Observation.self, from: data)
    }

    private func fetchEvent(id: UUID) throws -> ActivityEvent? {
        let statement = try prepare("SELECT payload FROM events WHERE id = ? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        try bind([.text(id.uuidString)], to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let data = blob(at: 0, statement: statement) else { return nil }
        return try decoder.decode(ActivityEvent.self, from: data)
    }

    private func fetchEvents(sql: String, arguments: [SQLiteBoundValue]) throws -> [ActivityEvent] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(arguments, to: statement)
        var values: [ActivityEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let data = blob(at: 0, statement: statement),
               let event = try? decoder.decode(ActivityEvent.self, from: data) {
                values.append(event)
            }
        }
        return values
    }

    private func stringColumn(sql: String, arguments: [SQLiteBoundValue]) throws -> [String] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(arguments, to: statement)
        var values: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = string(at: 0, statement: statement) { values.append(value) }
        }
        return values
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String, _ arguments: [SQLiteBoundValue] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(arguments, to: statement)
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw sqliteError(code: code, sql: sql) }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let database else { throw SQLiteStoreError.openFailed("Database is closed") }
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else { throw sqliteError(code: code, sql: sql) }
        return statement
    }

    private func bind(_ values: [SQLiteBoundValue], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .text(let string):
                code = string.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
            case .int(let integer):
                code = sqlite3_bind_int64(statement, index, integer)
            case .double(let double):
                code = sqlite3_bind_double(statement, index, double)
            case .blob(let data):
                code = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transient)
                }
            case .null:
                code = sqlite3_bind_null(statement, index)
            }
            guard code == SQLITE_OK else { throw sqliteError(code: code, sql: nil) }
        }
    }

    private func blob(at index: Int32, statement: OpaquePointer) -> Data? {
        guard let pointer = sqlite3_column_blob(statement, index) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        return Data(bytes: pointer, count: count)
    }

    private func string(at index: Int32, statement: OpaquePointer) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    private func sqliteError(code: Int32, sql: String?) -> SQLiteStoreError {
        let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
        return .sqlite(code: code, message: message, sql: sql)
    }

    private func persist() throws {
        guard let database else { throw SQLiteStoreError.openFailed("Database is closed") }
        var size: sqlite3_int64 = 0
        guard let pointer = sqlite3_serialize(database, "main", &size, 0) else {
            throw SQLiteStoreError.serializationFailed
        }
        defer { sqlite3_free(pointer) }
        let plain = Data(bytes: pointer, count: Int(size))
        let encrypted = try crypto.seal(plain, authenticating: Data("IrizSQLiteV1".utf8))
        try encrypted.write(to: databaseFile, options: [.atomic, .completeFileProtection])
    }

    private static func loadEncryptedDatabase(from url: URL, into database: OpaquePointer, crypto: CryptoBox) throws {
        let encrypted = try Data(contentsOf: url)
        let plain = try crypto.open(encrypted, authenticating: Data("IrizSQLiteV1".utf8))
        let capacity = max(plain.count, 64 * 1024)
        guard let buffer = sqlite3_malloc64(sqlite3_uint64(capacity)) else {
            throw SQLiteStoreError.invalidStoredData
        }
        plain.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: plain.count)
        let flags = UInt32(SQLITE_DESERIALIZE_FREEONCLOSE | SQLITE_DESERIALIZE_RESIZEABLE)
        let code = sqlite3_deserialize(
            database,
            "main",
            buffer.assumingMemoryBound(to: UInt8.self),
            sqlite3_int64(plain.count),
            sqlite3_int64(capacity),
            flags
        )
        guard code == SQLITE_OK else {
            sqlite3_free(buffer)
            throw SQLiteStoreError.sqlite(code: code, message: String(cString: sqlite3_errmsg(database)), sql: nil)
        }
    }

    private static func execute(_ sql: String, on database: OpaquePointer) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(database, sql, nil, nil, &errorPointer)
        guard code == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            if let errorPointer { sqlite3_free(errorPointer) }
            throw SQLiteStoreError.sqlite(code: code, message: message, sql: sql)
        }
    }

    private static let schemaSQL = """
        PRAGMA foreign_keys = ON;
        CREATE TABLE IF NOT EXISTS events (
            id TEXT PRIMARY KEY NOT NULL,
            started_at REAL NOT NULL,
            ended_at REAL NOT NULL,
            importance INTEGER NOT NULL,
            status TEXT NOT NULL,
            kind TEXT NOT NULL,
            language TEXT NOT NULL,
            payload BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS events_started_at ON events(started_at DESC);
        CREATE INDEX IF NOT EXISTS events_importance ON events(importance);
        CREATE VIRTUAL TABLE IF NOT EXISTS event_fts USING fts5(
            id UNINDEXED,
            title,
            summary,
            details,
            entities,
            urls,
            applications,
            tokenize = 'unicode61 remove_diacritics 2'
        );
        CREATE TABLE IF NOT EXISTS observations (
            id TEXT PRIMARY KEY NOT NULL,
            captured_at REAL NOT NULL,
            expires_at REAL NOT NULL,
            source TEXT NOT NULL,
            processed_at REAL,
            payload BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS observations_pending ON observations(processed_at, expires_at);
        CREATE TABLE IF NOT EXISTS commitments (
            id TEXT PRIMARY KEY NOT NULL,
            event_id TEXT NOT NULL REFERENCES events(id) ON DELETE CASCADE,
            state TEXT NOT NULL,
            review_at REAL,
            confidence REAL NOT NULL,
            payload BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS commitments_state_review ON commitments(state, review_at);
        CREATE TABLE IF NOT EXISTS assistant_conversations (
            id TEXT PRIMARY KEY NOT NULL,
            updated_at REAL NOT NULL,
            payload BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS assistant_conversations_updated_at ON assistant_conversations(updated_at DESC);
        """
}
