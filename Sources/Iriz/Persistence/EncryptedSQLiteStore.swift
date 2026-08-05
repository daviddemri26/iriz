import CryptoKit
import Foundation
import SQLite3

enum SQLiteStoreError: LocalizedError {
    case openFailed(String)
    case sqlite(code: Int32, message: String, sql: String?)
    case serializationFailed
    case invalidStoredData
    case invalidCommitment(String)
    case invalidFollowUpSubject(String)
    case invalidFollowUpType(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message): "Unable to open local memory: \(message)"
        case .sqlite(let code, let message, let sql):
            "SQLite error \(code): \(message)\(sql.map { " while running \($0)" } ?? "")"
        case .serializationFailed: "Local memory could not be encrypted."
        case .invalidStoredData: "Encrypted memory could not be decoded."
        case .invalidCommitment(let reason): "The Action could not be saved: \(reason)"
        case .invalidFollowUpSubject(let reason): "The Action subject could not be saved: \(reason)"
        case .invalidFollowUpType(let reason): "The Action type could not be saved: \(reason)"
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
        try transaction {
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
            if observation.processedAt == nil {
                try insertAnalysisJobIfNeeded(observationID: observation.id, at: observation.capturedAt)
            }
        }
        try persist()
    }

    func markObservationProcessed(id: UUID, at date: Date) async throws {
        guard var value = try fetchObservation(id: id) else { return }
        value.processedAt = date
        let payload = try encoder.encode(value)
        try transaction {
            try execute(
                "UPDATE observations SET processed_at = ?, payload = ? WHERE id = ?",
                [.double(date.timeIntervalSince1970), .blob(payload), .text(id.uuidString)]
            )
            try execute("DELETE FROM analysis_jobs WHERE observation_id = ?", [.text(id.uuidString)])
        }
        try persist()
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

    func enqueueAnalysis(observationID: UUID, at date: Date = Date()) async throws {
        try insertAnalysisJobIfNeeded(observationID: observationID, at: date)
        try persist()
    }

    func claimAnalysisJobs(
        limit: Int,
        now: Date = Date(),
        leaseDuration: TimeInterval = 10 * 60
    ) async throws -> [AnalysisJob] {
        let boundedLimit = max(0, limit)
        guard boundedLimit > 0 else { return [] }
        let nowValue = now.timeIntervalSince1970
        let leaseValue = now.addingTimeInterval(leaseDuration).timeIntervalSince1970
        var jobs: [AnalysisJob] = []
        try transaction {
            try execute(
                """
                UPDATE analysis_jobs
                SET state = 'retryable', lease_expires_at = NULL, updated_at = ?
                WHERE state = 'running' AND lease_expires_at IS NOT NULL AND lease_expires_at <= ?
                """,
                [.double(nowValue), .double(nowValue)]
            )
            let statement = try prepare(
                """
                SELECT id, observation_id, state, attempts, next_attempt_at, lease_expires_at,
                       last_error_kind, last_error_message, created_at, updated_at
                FROM analysis_jobs
                WHERE state IN ('queued', 'retryable') AND next_attempt_at <= ?
                ORDER BY next_attempt_at ASC, created_at ASC
                LIMIT ?
                """
            )
            defer { sqlite3_finalize(statement) }
            try bind([.double(nowValue), .int(Int64(boundedLimit))], to: statement)
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let job = analysisJob(from: statement) else { continue }
                jobs.append(job)
            }
            for job in jobs {
                try execute(
                    """
                    UPDATE analysis_jobs
                    SET state = 'running', attempts = attempts + 1, lease_expires_at = ?, updated_at = ?
                    WHERE id = ?
                    """,
                    [.double(leaseValue), .double(nowValue), .text(job.id.uuidString)]
                )
            }
        }
        if !jobs.isEmpty { try persist() }
        return jobs.map { job in
            var claimed = job
            claimed.state = .running
            claimed.attempts += 1
            claimed.leaseExpiresAt = Date(timeIntervalSince1970: leaseValue)
            claimed.updatedAt = now
            return claimed
        }
    }

    func completeAnalysisJob(id: UUID) async throws {
        try execute("DELETE FROM analysis_jobs WHERE id = ?", [.text(id.uuidString)])
        try persist()
    }

    func rescheduleAnalysisJob(
        id: UUID,
        state: AnalysisJobState,
        nextAttemptAt: Date,
        errorKind: AnalysisErrorKind?,
        errorMessage: String?
    ) async throws {
        try execute(
            """
            UPDATE analysis_jobs
            SET state = ?, next_attempt_at = ?, lease_expires_at = NULL,
                last_error_kind = ?, last_error_message = ?, updated_at = ?
            WHERE id = ?
            """,
            [
                .text(state.rawValue),
                .double(nextAttemptAt.timeIntervalSince1970),
                errorKind.map { .text($0.rawValue) } ?? .null,
                errorMessage.map(SQLiteBoundValue.text) ?? .null,
                .double(Date().timeIntervalSince1970),
                .text(id.uuidString)
            ]
        )
        try persist()
    }

    func unblockCredentialAnalysisJobs(at date: Date = Date()) async throws {
        try execute(
            """
            UPDATE analysis_jobs
            SET state = 'retryable', next_attempt_at = ?, lease_expires_at = NULL, updated_at = ?
            WHERE state = 'blockedCredentials'
            """,
            [.double(date.timeIntervalSince1970), .double(date.timeIntervalSince1970)]
        )
        try persist()
    }

    func pendingAnalysisJobCount() async throws -> Int {
        let statement = try prepare(
            "SELECT COUNT(*) FROM analysis_jobs WHERE state NOT IN ('terminal')"
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func enqueueRefinement(
        eventID: UUID,
        eventRevision: Date,
        isCritical: Bool,
        notBefore: Date
    ) async throws {
        let now = Date()
        try execute(
            """
            INSERT INTO refinement_jobs (
                id, event_id, event_revision, is_critical, state, attempts,
                next_attempt_at, lease_expires_at, last_error_kind, last_error_message,
                created_at, updated_at
            ) VALUES (?, ?, ?, ?, 'queued', 0, ?, NULL, NULL, NULL, ?, ?)
            ON CONFLICT(event_id) DO UPDATE SET
                event_revision = excluded.event_revision,
                is_critical = MAX(refinement_jobs.is_critical, excluded.is_critical),
                state = 'queued',
                attempts = 0,
                next_attempt_at = excluded.next_attempt_at,
                lease_expires_at = NULL,
                last_error_kind = NULL,
                last_error_message = NULL,
                updated_at = excluded.updated_at
            """,
            [
                .text(UUID().uuidString),
                .text(eventID.uuidString),
                .double(eventRevision.timeIntervalSince1970),
                .int(isCritical ? 1 : 0),
                .double(notBefore.timeIntervalSince1970),
                .double(now.timeIntervalSince1970),
                .double(now.timeIntervalSince1970)
            ]
        )
        try persist()
    }

    func claimRefinementJobs(
        limit: Int,
        now: Date = Date(),
        leaseDuration: TimeInterval = 20 * 60
    ) async throws -> [RefinementJob] {
        let boundedLimit = max(0, limit)
        guard boundedLimit > 0 else { return [] }
        let nowValue = now.timeIntervalSince1970
        let leaseValue = now.addingTimeInterval(leaseDuration).timeIntervalSince1970
        var jobs: [RefinementJob] = []
        try transaction {
            try execute(
                """
                UPDATE refinement_jobs
                SET state = 'retryable', lease_expires_at = NULL, updated_at = ?
                WHERE state = 'running' AND lease_expires_at IS NOT NULL AND lease_expires_at <= ?
                """,
                [.double(nowValue), .double(nowValue)]
            )
            let statement = try prepare(
                """
                SELECT id, event_id, event_revision, is_critical, state, attempts,
                       next_attempt_at, lease_expires_at, last_error_kind, last_error_message,
                       created_at, updated_at
                FROM refinement_jobs
                WHERE state IN ('queued', 'retryable') AND next_attempt_at <= ?
                ORDER BY is_critical DESC, next_attempt_at ASC, created_at ASC
                LIMIT ?
                """
            )
            defer { sqlite3_finalize(statement) }
            try bind([.double(nowValue), .int(Int64(boundedLimit))], to: statement)
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let job = refinementJob(from: statement) else { continue }
                jobs.append(job)
            }
            for job in jobs {
                try execute(
                    """
                    UPDATE refinement_jobs
                    SET state = 'running', attempts = attempts + 1, lease_expires_at = ?, updated_at = ?
                    WHERE id = ?
                    """,
                    [.double(leaseValue), .double(nowValue), .text(job.id.uuidString)]
                )
            }
        }
        if !jobs.isEmpty { try persist() }
        return jobs.map { job in
            var claimed = job
            claimed.state = .running
            claimed.attempts += 1
            claimed.leaseExpiresAt = Date(timeIntervalSince1970: leaseValue)
            claimed.updatedAt = now
            return claimed
        }
    }

    func completeRefinementJob(id: UUID) async throws {
        try execute("DELETE FROM refinement_jobs WHERE id = ?", [.text(id.uuidString)])
        try persist()
    }

    func rescheduleRefinementJob(
        id: UUID,
        state: AnalysisJobState,
        nextAttemptAt: Date,
        errorKind: AnalysisErrorKind?,
        errorMessage: String?
    ) async throws {
        try execute(
            """
            UPDATE refinement_jobs
            SET state = ?, next_attempt_at = ?, lease_expires_at = NULL,
                last_error_kind = ?, last_error_message = ?, updated_at = ?
            WHERE id = ?
            """,
            [
                .text(state.rawValue),
                .double(nextAttemptAt.timeIntervalSince1970),
                errorKind.map { .text($0.rawValue) } ?? .null,
                errorMessage.map(SQLiteBoundValue.text) ?? .null,
                .double(Date().timeIntervalSince1970),
                .text(id.uuidString)
            ]
        )
        try persist()
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
        try validate(commitment)
        let payload = try encoder.encode(commitment)
        try upsertCommitment(commitment, payload: payload)
        try persist()
    }

    func commitments(includingClosed: Bool = false) async throws -> [Commitment] {
        let records = try commitmentRecords()
        try migrateLegacyCommitmentsAndSubjects(records)
        let values = records.lazy.map(\.commitment).filter {
            includingClosed || ($0.lifecycle != .completed && $0.lifecycle != .dismissed)
        }
        return values.sorted {
            if $0.surfacedAt != $1.surfacedAt { return $0.surfacedAt > $1.surfacedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    func replaceCommitments(
        with mergedCommitment: Commitment,
        deletingSourceIDs sourceIDs: [UUID]
    ) async throws {
        try validate(mergedCommitment)
        let payload = try encoder.encode(mergedCommitment)
        let identifiersToDelete = Set(sourceIDs).subtracting([mergedCommitment.id])

        try transaction {
            // The replacement is encoded, validated, and inserted before any source row is removed.
            try upsertCommitment(mergedCommitment, payload: payload)
            for identifier in identifiersToDelete {
                try execute("DELETE FROM commitments WHERE id = ?", [.text(identifier.uuidString)])
            }
        }
        try persist()
    }

    func saveFollowUpSubject(_ subject: FollowUpSubject) async throws {
        try validate(subject)
        let payload = try encoder.encode(subject)
        try execute(
            """
            INSERT INTO follow_up_subjects (id, name, area, updated_at, payload)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                area = excluded.area,
                updated_at = excluded.updated_at,
                payload = excluded.payload
            """,
            [
                .text(subject.id),
                .text(subject.name),
                .text(subject.area.rawValue),
                .double(subject.updatedAt.timeIntervalSince1970),
                .blob(payload)
            ]
        )
        try persist()
    }

    func followUpSubject(id: String) async throws -> FollowUpSubject? {
        try migrateLegacyCommitmentsAndSubjects(commitmentRecords())
        let statement = try prepare("SELECT payload FROM follow_up_subjects WHERE id = ? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        try bind([.text(id)], to: statement)
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW else {
            throw sqliteError(code: code, sql: "SELECT payload FROM follow_up_subjects WHERE id = ? LIMIT 1")
        }
        guard let data = blob(at: 0, statement: statement) else {
            throw SQLiteStoreError.invalidStoredData
        }
        return try decoder.decode(FollowUpSubject.self, from: data)
    }

    func followUpSubjects() async throws -> [FollowUpSubject] {
        try migrateLegacyCommitmentsAndSubjects(commitmentRecords())
        let statement = try prepare(
            "SELECT payload FROM follow_up_subjects ORDER BY name COLLATE NOCASE ASC, id ASC"
        )
        defer { sqlite3_finalize(statement) }
        var values: [FollowUpSubject] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else {
                throw sqliteError(code: code, sql: "SELECT payload FROM follow_up_subjects")
            }
            guard let data = blob(at: 0, statement: statement) else {
                throw SQLiteStoreError.invalidStoredData
            }
            values.append(try decoder.decode(FollowUpSubject.self, from: data))
        }
        return values
    }

    func deleteFollowUpSubject(id: String) async throws {
        try execute("DELETE FROM follow_up_subjects WHERE id = ?", [.text(id)])
        try persist()
    }

    func saveFollowUpType(_ type: FollowUpType) async throws {
        try validate(type)
        let payload = try encoder.encode(type)
        try execute(
            """
            INSERT INTO follow_up_types (id, name, updated_at, payload)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                updated_at = excluded.updated_at,
                payload = excluded.payload
            """,
            [
                .text(type.id),
                .text(type.name),
                .double(type.updatedAt.timeIntervalSince1970),
                .blob(payload)
            ]
        )
        try persist()
    }

    func followUpTypes() async throws -> [FollowUpType] {
        let statement = try prepare("SELECT payload FROM follow_up_types ORDER BY name COLLATE NOCASE ASC, id ASC")
        defer { sqlite3_finalize(statement) }
        var values: [FollowUpType] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else {
                throw sqliteError(code: code, sql: "SELECT payload FROM follow_up_types")
            }
            guard let data = blob(at: 0, statement: statement) else {
                throw SQLiteStoreError.invalidStoredData
            }
            values.append(try decoder.decode(FollowUpType.self, from: data))
        }
        return values
    }

    func deleteFollowUpType(id: String) async throws {
        try execute("DELETE FROM follow_up_types WHERE id = ?", [.text(id)])
        try persist()
    }

    func resetFollowUps() async throws {
        try transaction {
            try execute("DELETE FROM commitments")
            try execute("DELETE FROM follow_up_subjects")
        }
        try persist()
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
        let expiredCompletedIDs: [UUID]
        if let interval = retention.cutoffInterval {
            let cutoff = now.addingTimeInterval(-interval)
            expiredCompletedIDs = try commitmentRecords().compactMap { record in
                guard record.commitment.lifecycle == .completed,
                      (record.commitment.completedAt ?? record.commitment.updatedAt) < cutoff else { return nil }
                return record.commitment.id
            }
        } else {
            expiredCompletedIDs = []
        }
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
            for id in expiredCompletedIDs {
                try execute("DELETE FROM commitments WHERE id = ?", [.text(id.uuidString)])
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

    private func insertAnalysisJobIfNeeded(observationID: UUID, at date: Date) throws {
        let value = date.timeIntervalSince1970
        try execute(
            """
            INSERT OR IGNORE INTO analysis_jobs (
                id, observation_id, state, attempts, next_attempt_at, lease_expires_at,
                last_error_kind, last_error_message, created_at, updated_at
            ) VALUES (?, ?, 'queued', 0, ?, NULL, NULL, NULL, ?, ?)
            """,
            [
                .text(UUID().uuidString),
                .text(observationID.uuidString),
                .double(value),
                .double(value),
                .double(value)
            ]
        )
    }

    private func analysisJob(from statement: OpaquePointer) -> AnalysisJob? {
        guard let idText = string(at: 0, statement: statement),
              let id = UUID(uuidString: idText),
              let observationText = string(at: 1, statement: statement),
              let observationID = UUID(uuidString: observationText),
              let stateText = string(at: 2, statement: statement),
              let state = AnalysisJobState(rawValue: stateText) else { return nil }
        return AnalysisJob(
            id: id,
            observationID: observationID,
            state: state,
            attempts: Int(sqlite3_column_int64(statement, 3)),
            nextAttemptAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
            leaseExpiresAt: optionalDate(at: 5, statement: statement),
            lastErrorKind: string(at: 6, statement: statement).flatMap(AnalysisErrorKind.init(rawValue:)),
            lastErrorMessage: string(at: 7, statement: statement),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9))
        )
    }

    private func refinementJob(from statement: OpaquePointer) -> RefinementJob? {
        guard let idText = string(at: 0, statement: statement),
              let id = UUID(uuidString: idText),
              let eventText = string(at: 1, statement: statement),
              let eventID = UUID(uuidString: eventText),
              let stateText = string(at: 4, statement: statement),
              let state = AnalysisJobState(rawValue: stateText) else { return nil }
        return RefinementJob(
            id: id,
            eventID: eventID,
            eventRevision: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
            isCritical: sqlite3_column_int(statement, 3) != 0,
            state: state,
            attempts: Int(sqlite3_column_int64(statement, 5)),
            nextAttemptAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            leaseExpiresAt: optionalDate(at: 7, statement: statement),
            lastErrorKind: string(at: 8, statement: statement).flatMap(AnalysisErrorKind.init(rawValue:)),
            lastErrorMessage: string(at: 9, statement: statement),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 11))
        )
    }

    private func optionalDate(at index: Int32, statement: OpaquePointer) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
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

    private func upsertCommitment(_ commitment: Commitment, payload: Data) throws {
        let reviewAt = commitment.snoozedUntil ?? commitment.explicitDueAt
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
                .text(commitment.lifecycle.rawValue),
                reviewAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                .double(commitment.confidence),
                .blob(payload)
            ]
        )
    }

    private func commitmentRecords() throws -> [(commitment: Commitment, requiresMigration: Bool)] {
        let statement = try prepare("SELECT payload FROM commitments")
        defer { sqlite3_finalize(statement) }
        var records: [(commitment: Commitment, requiresMigration: Bool)] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else {
                throw sqliteError(code: code, sql: "SELECT payload FROM commitments")
            }
            guard let data = blob(at: 0, statement: statement) else {
                throw SQLiteStoreError.invalidStoredData
            }
            let commitment = try decoder.decode(Commitment.self, from: data)
            records.append((commitment, isLegacyCommitmentPayload(data)))
        }
        return records
    }

    private func isLegacyCommitmentPayload(_ payload: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return false
        }
        return object["lifecycle"] == nil
    }

    private func migrateLegacyCommitmentsAndSubjects(
        _ records: [(commitment: Commitment, requiresMigration: Bool)]
    ) throws {
        var subjectsByID: [String: FollowUpSubject] = [:]
        for record in records {
            let commitment = record.commitment
            guard let subjectID = commitment.subjectID,
                  let label = commitment.contextLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !label.isEmpty else { continue }
            let candidate = FollowUpSubject(
                id: subjectID,
                name: label,
                area: commitment.area,
                color: .stable(for: label),
                createdAt: commitment.createdAt,
                updatedAt: commitment.updatedAt
            )
            if let existing = subjectsByID[subjectID] {
                if candidate.updatedAt > existing.updatedAt { subjectsByID[subjectID] = candidate }
            } else {
                subjectsByID[subjectID] = candidate
            }
        }

        if !subjectsByID.isEmpty {
            let existingIDs = Set(try stringColumn(sql: "SELECT id FROM follow_up_subjects", arguments: []))
            subjectsByID = subjectsByID.filter { !existingIDs.contains($0.key) }
        }

        guard records.contains(where: { $0.requiresMigration }) || !subjectsByID.isEmpty else { return }
        var madeChanges = false
        try transaction {
            for record in records where record.requiresMigration {
                let commitment = record.commitment
                let payload = try encoder.encode(commitment)
                let reviewAt = commitment.snoozedUntil ?? commitment.explicitDueAt ?? commitment.suggestedReviewAt
                try execute(
                    """
                    UPDATE commitments
                    SET state = ?, review_at = ?, confidence = ?, payload = ?
                    WHERE id = ?
                    """,
                    [
                        .text(commitment.lifecycle.rawValue),
                        reviewAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                        .double(commitment.confidence),
                        .blob(payload),
                        .text(commitment.id.uuidString)
                    ]
                )
                madeChanges = true
            }

            for subject in subjectsByID.values {
                let payload = try encoder.encode(subject)
                try execute(
                    """
                    INSERT OR IGNORE INTO follow_up_subjects (id, name, area, updated_at, payload)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    [
                        .text(subject.id),
                        .text(subject.name),
                        .text(subject.area.rawValue),
                        .double(subject.updatedAt.timeIntervalSince1970),
                        .blob(payload)
                    ]
                )
                if let database, sqlite3_changes(database) > 0 { madeChanges = true }
            }
        }
        if madeChanges { try persist() }
    }

    private func validate(_ commitment: Commitment) throws {
        guard !commitment.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SQLiteStoreError.invalidCommitment("an action is required")
        }
        guard commitment.confidence.isFinite, (0...1).contains(commitment.confidence) else {
            throw SQLiteStoreError.invalidCommitment("confidence must be between 0 and 1")
        }
        guard (0...10).contains(commitment.aiPriorityScore) else {
            throw SQLiteStoreError.invalidCommitment("AI priority must be between 0 and 10")
        }
        guard (0...10).contains(commitment.displayPriorityScore) else {
            throw SQLiteStoreError.invalidCommitment("display priority must be between 0 and 10")
        }
        if let userPriorityScore = commitment.userPriorityScore, !(0...10).contains(userPriorityScore) {
            throw SQLiteStoreError.invalidCommitment("user priority must be between 0 and 10")
        }
        if let dueConfidence = commitment.dueConfidence,
           (!dueConfidence.isFinite || !(0...1).contains(dueConfidence)) {
            throw SQLiteStoreError.invalidCommitment("due-date confidence must be between 0 and 1")
        }
    }

    private func validate(_ subject: FollowUpSubject) throws {
        guard !subject.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SQLiteStoreError.invalidFollowUpSubject("an identifier is required")
        }
        guard !subject.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SQLiteStoreError.invalidFollowUpSubject("a name is required")
        }
        guard subject.priorityBias.isFinite, (-3...3).contains(subject.priorityBias) else {
            throw SQLiteStoreError.invalidFollowUpSubject("priority bias must be between -3 and 3")
        }
        guard subject.correctionCount >= 0 else {
            throw SQLiteStoreError.invalidFollowUpSubject("correction count cannot be negative")
        }
    }

    private func validate(_ type: FollowUpType) throws {
        guard !type.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SQLiteStoreError.invalidFollowUpType("an identifier is required")
        }
        guard !type.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SQLiteStoreError.invalidFollowUpType("a name is required")
        }
        guard !type.systemImage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SQLiteStoreError.invalidFollowUpType("an icon is required")
        }
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
        CREATE TABLE IF NOT EXISTS analysis_jobs (
            id TEXT PRIMARY KEY NOT NULL,
            observation_id TEXT UNIQUE NOT NULL REFERENCES observations(id) ON DELETE CASCADE,
            state TEXT NOT NULL,
            attempts INTEGER NOT NULL,
            next_attempt_at REAL NOT NULL,
            lease_expires_at REAL,
            last_error_kind TEXT,
            last_error_message TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS analysis_jobs_ready
            ON analysis_jobs(state, next_attempt_at, created_at);
        INSERT OR IGNORE INTO analysis_jobs (
            id, observation_id, state, attempts, next_attempt_at, lease_expires_at,
            last_error_kind, last_error_message, created_at, updated_at
        )
        SELECT
            lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-' ||
            lower(hex(randomblob(2))) || '-' || lower(hex(randomblob(2))) || '-' ||
            lower(hex(randomblob(6))),
            id, 'queued', 0, captured_at, NULL, NULL, NULL, captured_at, captured_at
        FROM observations
        WHERE processed_at IS NULL AND expires_at > unixepoch();
        CREATE TABLE IF NOT EXISTS refinement_jobs (
            id TEXT PRIMARY KEY NOT NULL,
            event_id TEXT UNIQUE NOT NULL REFERENCES events(id) ON DELETE CASCADE,
            event_revision REAL NOT NULL,
            is_critical INTEGER NOT NULL,
            state TEXT NOT NULL,
            attempts INTEGER NOT NULL,
            next_attempt_at REAL NOT NULL,
            lease_expires_at REAL,
            last_error_kind TEXT,
            last_error_message TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS refinement_jobs_ready
            ON refinement_jobs(state, is_critical DESC, next_attempt_at, created_at);
        CREATE TABLE IF NOT EXISTS commitments (
            id TEXT PRIMARY KEY NOT NULL,
            event_id TEXT NOT NULL REFERENCES events(id) ON DELETE CASCADE,
            state TEXT NOT NULL,
            review_at REAL,
            confidence REAL NOT NULL,
            payload BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS commitments_state_review ON commitments(state, review_at);
        CREATE TABLE IF NOT EXISTS follow_up_subjects (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            area TEXT NOT NULL,
            updated_at REAL NOT NULL,
            payload BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS follow_up_subjects_area_name ON follow_up_subjects(area, name COLLATE NOCASE);
        CREATE INDEX IF NOT EXISTS follow_up_subjects_updated_at ON follow_up_subjects(updated_at DESC);
        CREATE TABLE IF NOT EXISTS follow_up_types (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            updated_at REAL NOT NULL,
            payload BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS follow_up_types_name ON follow_up_types(name COLLATE NOCASE);
        CREATE TABLE IF NOT EXISTS assistant_conversations (
            id TEXT PRIMARY KEY NOT NULL,
            updated_at REAL NOT NULL,
            payload BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS assistant_conversations_updated_at ON assistant_conversations(updated_at DESC);
        """
}
