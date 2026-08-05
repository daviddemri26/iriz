import Foundation
import SQLite3
import Testing
@testable import Iriz

@Suite("Follow-up persistence")
struct FollowUpPersistenceTests {
    private let keyData = Data(repeating: 0x2A, count: 32)

    @Test("Subjects round-trip through the encrypted serialized database")
    func subjectCRUDAndEncryption() async throws {
        let directory = temporaryDirectory(named: "Subjects")
        defer { try? FileManager.default.removeItem(at: directory) }

        let subject = FollowUpSubject(
            id: "road-sight",
            name: "RoadSight Launch",
            area: .work,
            color: .indigo,
            aliases: ["RoadSight", "Camera launch"],
            priorityBias: 1.25,
            correctionCount: 4,
            createdAt: Date(timeIntervalSince1970: 1_900_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_900_000_100)
        )

        do {
            let store = try EncryptedSQLiteStore(directory: directory, keyData: keyData)
            try await store.saveFollowUpSubject(subject)
            #expect(try await store.followUpSubject(id: subject.id) == subject)
            #expect(try await store.followUpSubjects() == [subject])

            var updated = subject
            updated.name = "RoadSight Release"
            updated.aliases.insert("Release")
            updated.updatedAt = updated.updatedAt.addingTimeInterval(60)
            try await store.saveFollowUpSubject(updated)
            #expect(try await store.followUpSubject(id: subject.id) == updated)
        }

        let encryptedFile = directory.appendingPathComponent("Iriz.sqlite.iriz")
        let encryptedBytes = try Data(contentsOf: encryptedFile)
        #expect(!String(decoding: encryptedBytes, as: UTF8.self).contains("RoadSight Release"))

        let reopened = try EncryptedSQLiteStore(directory: directory, keyData: keyData)
        #expect(try await reopened.followUpSubject(id: subject.id)?.name == "RoadSight Release")
        try await reopened.deleteFollowUpSubject(id: subject.id)
        #expect(try await reopened.followUpSubject(id: subject.id) == nil)
        #expect(try await reopened.followUpSubjects().isEmpty)
    }

    @Test("User-managed types round-trip encrypted and subjects retain their type")
    func typeCRUDAndSubjectAssignment() async throws {
        let directory = temporaryDirectory(named: "Types")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try EncryptedSQLiteStore(directory: directory, keyData: keyData)
        let type = FollowUpType(
            id: "type-client",
            name: "Client",
            area: .work,
            color: .teal,
            systemImage: "building.2.fill"
        )
        let subject = FollowUpSubject(
            id: "client-northstar",
            name: "Client Northstar",
            area: .work,
            typeID: type.id,
            color: .mint
        )

        try await store.saveFollowUpType(type)
        try await store.saveFollowUpSubject(subject)
        #expect(try await store.followUpTypes().map(\.id) == [type.id])
        #expect(try await store.followUpSubject(id: subject.id)?.typeID == type.id)

        let encryptedBytes = try Data(contentsOf: directory.appendingPathComponent("Iriz.sqlite.iriz"))
        #expect(!String(decoding: encryptedBytes, as: UTF8.self).contains("Client Northstar"))

        let reopened = try EncryptedSQLiteStore(directory: directory, keyData: keyData)
        #expect(try await reopened.followUpTypes().first?.name == "Client")
        try await reopened.deleteFollowUpType(id: type.id)
        #expect(try await reopened.followUpTypes().isEmpty)
    }

    @Test("Lifecycle queries retain snoozed and every closed item when requested")
    func lifecycleCompatibleQueries() async throws {
        let directory = temporaryDirectory(named: "Lifecycle")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try EncryptedSQLiteStore(directory: directory, keyData: keyData)

        let base = Date(timeIntervalSince1970: 1_900_000_000)
        let lifecycles: [FollowUpLifecycle] = [.active, .snoozed, .completed, .dismissed]
        var expectedIDs: [String: UUID] = [:]
        for (index, lifecycle) in lifecycles.enumerated() {
            let event = makeEvent(title: lifecycle.rawValue)
            try await store.saveEvent(event)
            let commitment = Commitment(
                eventID: event.id,
                owner: "You",
                action: "Persist \(lifecycle.rawValue)",
                confidence: 0.9,
                state: lifecycle.legacyState,
                createdAt: base.addingTimeInterval(Double(index)),
                updatedAt: base.addingTimeInterval(Double(index)),
                lifecycle: lifecycle,
                surfacedAt: base.addingTimeInterval(Double(index)),
                snoozedUntil: lifecycle == .snoozed ? base.addingTimeInterval(86_400) : nil,
                completedAt: lifecycle == .completed ? base : nil,
                dismissedAt: lifecycle == .dismissed ? base : nil
            )
            expectedIDs[lifecycle.rawValue] = commitment.id
            try await store.saveCommitment(commitment)
        }

        let open = try await store.commitments(includingClosed: false)
        #expect(Set(open.map(\.lifecycle.rawValue)) == Set(["active", "snoozed"]))
        #expect(open.map(\.surfacedAt) == open.map(\.surfacedAt).sorted(by: >))

        let all = try await store.commitments(includingClosed: true)
        #expect(all.count == lifecycles.count)
        #expect(Set(all.map(\.id)) == Set(expectedIDs.values))
        #expect(Set(all.map(\.lifecycle.rawValue)) == Set(lifecycles.map(\.rawValue)))
    }

    @Test("Rich follow-up metadata and history survive an encrypted reopen")
    func richFollowUpRoundTrip() async throws {
        let directory = temporaryDirectory(named: "RichFollowUp")
        defer { try? FileManager.default.removeItem(at: directory) }
        let timestamp = Date(timeIntervalSince1970: 1_900_000_000)
        let sourceEvent = makeEvent(title: "Camera brief sent")
        let evidenceEventID = UUID()
        let value = Commitment(
            eventID: sourceEvent.id,
            owner: "David",
            action: "Send the RoadSight camera brief",
            rationale: "The customer requested it during the call.",
            explicitDueAt: timestamp.addingTimeInterval(3_600),
            contextLabel: "RoadSight",
            isPriority: true,
            confidence: 0.94,
            state: .completed,
            linkedEventIDs: [evidenceEventID],
            createdAt: timestamp.addingTimeInterval(-7_200),
            updatedAt: timestamp,
            summary: "Send the requested specification.",
            details: "Include the low-light benchmarks and pricing appendix.",
            lifecycle: .completed,
            subjectID: "roadsight",
            area: .work,
            origin: .manual,
            detailLevelAtCreation: .detailed,
            aiPriorityScore: 8,
            displayPriorityScore: 10,
            userPriorityScore: 9,
            priorityReason: "Customer deadline",
            surfacedAt: timestamp.addingTimeInterval(-3_600),
            completedAt: timestamp,
            completionActor: .user,
            completionEvidence: FollowUpCompletionEvidence(
                eventID: evidenceEventID,
                summary: "The email confirmation was observed.",
                confidence: 0.96,
                strength: .explicit,
                capturedAt: timestamp
            ),
            dueSource: .user,
            dueConfidence: 1,
            evidenceHint: "Email confirmation",
            manuallyEditedFields: [.action, .details, .priority, .dueDate],
            history: [
                FollowUpHistoryEntry(
                    kind: .created,
                    actor: .user,
                    summary: "Created manually",
                    occurredAt: timestamp.addingTimeInterval(-7_200)
                ),
                FollowUpHistoryEntry(
                    kind: .completed,
                    actor: .user,
                    summary: "Marked complete",
                    occurredAt: timestamp,
                    eventID: evidenceEventID
                )
            ]
        )

        do {
            let store = try EncryptedSQLiteStore(directory: directory, keyData: keyData)
            try await store.saveEvent(sourceEvent)
            try await store.saveCommitment(value)
        }

        let encryptedBytes = try Data(contentsOf: directory.appendingPathComponent("Iriz.sqlite.iriz"))
        #expect(!String(decoding: encryptedBytes, as: UTF8.self).contains(value.action))

        let reopened = try EncryptedSQLiteStore(directory: directory, keyData: keyData)
        let restoredValues = try await reopened.commitments(includingClosed: true)
        let restored = try #require(restoredValues.first)
        #expect(restored == value)
    }

    @Test("Reset clears only follow-ups and subjects while preserving Journal events")
    func targetedFollowUpReset() async throws {
        let directory = temporaryDirectory(named: "TargetedReset")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try EncryptedSQLiteStore(directory: directory, keyData: keyData)
        let event = makeEvent(title: "Journal event that must remain")
        let subject = FollowUpSubject(name: "Client Northstar", area: .work)
        let type = FollowUpType(id: "type-client", name: "Client", area: .work)
        let commitment = makeCommitment(eventID: event.id, action: "Send the Northstar brief")

        try await store.saveEvent(event)
        try await store.saveFollowUpSubject(subject)
        try await store.saveFollowUpType(type)
        try await store.saveCommitment(commitment)
        try await store.resetFollowUps()

        #expect(try await store.commitments(includingClosed: true).isEmpty)
        #expect(try await store.followUpSubjects().isEmpty)
        #expect(try await store.followUpTypes().map(\.id) == [type.id])
        #expect(try await store.event(id: event.id)?.title == event.title)
    }

    @Test("Suggested review dates are never exposed as deadlines")
    func suggestedReviewIsNotADeadline() {
        let suggested = Date(timeIntervalSince1970: 1_900_000_000)
        let commitment = Commitment(
            eventID: UUID(),
            owner: "You",
            action: "Continue the website work",
            suggestedReviewAt: suggested,
            confidence: 0.9,
            state: .needsAttention
        )
        let draft = CommitmentDraft(
            operation: .create,
            existingCommitmentID: nil,
            owner: "You",
            action: commitment.action,
            rationale: "",
            summary: "",
            details: "",
            explicitDueAt: nil,
            suggestedReviewAt: suggested,
            contextLabel: "Website",
            area: .work,
            priorityScore: 5,
            priorityReason: "",
            dueSource: .inferredByIriz,
            evidenceStrength: .weak,
            confidence: 0.9,
            state: .needsAttention
        )

        #expect(commitment.dueAt == nil)
        #expect(draft.dueAt == nil)
    }

    @Test("Atomic replacement inserts the merge before deleting its sources")
    func atomicCommitmentReplacement() async throws {
        let directory = temporaryDirectory(named: "Merge")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try EncryptedSQLiteStore(directory: directory, keyData: keyData)

        let firstEvent = makeEvent(title: "First source")
        let secondEvent = makeEvent(title: "Second source")
        for event in [firstEvent, secondEvent] {
            try await store.saveEvent(event)
        }

        let first = makeCommitment(eventID: firstEvent.id, action: "Send the brief")
        let second = makeCommitment(eventID: secondEvent.id, action: "Send the camera brief")
        try await store.saveCommitment(first)
        try await store.saveCommitment(second)

        var merged = first
        merged.action = "Send the camera brief to Morgan"
        merged.linkedEventIDs = [secondEvent.id]
        try await store.replaceCommitments(with: merged, deletingSourceIDs: [first.id, second.id])

        let afterSuccess = try await store.commitments(includingClosed: true)
        #expect(afterSuccess.map(\.id) == [merged.id])
        #expect(afterSuccess.first?.action == merged.action)

        let thirdEvent = makeEvent(title: "Third source")
        let fourthEvent = makeEvent(title: "Fourth source")
        try await store.saveEvent(thirdEvent)
        try await store.saveEvent(fourthEvent)
        let third = makeCommitment(eventID: thirdEvent.id, action: "Call Morgan")
        let fourth = makeCommitment(eventID: fourthEvent.id, action: "Confirm the deadline")
        try await store.saveCommitment(third)
        try await store.saveCommitment(fourth)

        let invalidReplacement = makeCommitment(eventID: UUID(), action: "Merged but invalid foreign key")
        await #expect(throws: SQLiteStoreError.self) {
            try await store.replaceCommitments(
                with: invalidReplacement,
                deletingSourceIDs: [third.id, fourth.id]
            )
        }

        let afterFailure = try await store.commitments(includingClosed: true)
        let remainingIDs = Set(afterFailure.map(\.id))
        #expect(remainingIDs.contains(third.id))
        #expect(remainingIDs.contains(fourth.id))
        #expect(!remainingIDs.contains(invalidReplacement.id))
    }

    @Test("An older encrypted database gains subjects without losing legacy follow-ups")
    func legacyEncryptedDatabaseMigration() async throws {
        let directory = temporaryDirectory(named: "Legacy")
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date()
        let legacyValues = [
            Commitment(
                eventID: UUID(), owner: "You", action: "Active legacy follow-up",
                contextLabel: "Work", confidence: 0.8, state: .maybe,
                createdAt: now.addingTimeInterval(-40), updatedAt: now.addingTimeInterval(-40)
            ),
            Commitment(
                eventID: UUID(), owner: "You", action: "Future legacy follow-up",
                suggestedReviewAt: now.addingTimeInterval(3_600), contextLabel: "RoadSight",
                confidence: 0.85, state: .later,
                createdAt: now.addingTimeInterval(-30), updatedAt: now.addingTimeInterval(-30)
            ),
            Commitment(
                eventID: UUID(), owner: "You", action: "Completed legacy follow-up",
                confidence: 0.9, state: .completed,
                createdAt: now.addingTimeInterval(-20), updatedAt: now.addingTimeInterval(-20)
            ),
            Commitment(
                eventID: UUID(), owner: "You", action: "Dismissed legacy follow-up",
                confidence: 0.7, state: .dismissed,
                createdAt: now.addingTimeInterval(-10), updatedAt: now.addingTimeInterval(-10)
            )
        ]
        try writeLegacyEncryptedDatabase(directory: directory, commitments: legacyValues)

        do {
            let migratedStore = try EncryptedSQLiteStore(directory: directory, keyData: keyData)
            let open = try await migratedStore.commitments(includingClosed: false)
            #expect(Set(open.map(\.lifecycle.rawValue)) == Set(["active", "snoozed"]))

            let all = try await migratedStore.commitments(includingClosed: true)
            #expect(all.count == legacyValues.count)
            #expect(Set(all.map(\.lifecycle.rawValue)) == Set(FollowUpLifecycle.allCases.map(\.rawValue)))
            #expect(all.first(where: { $0.action == "Future legacy follow-up" })?.subjectID == "roadsight")
            #expect(all.first(where: { $0.lifecycle == .completed })?.completionActor == .user)
            #expect(try await migratedStore.followUpSubject(id: "roadsight")?.name == "RoadSight")
        }

        let reopened = try EncryptedSQLiteStore(directory: directory, keyData: keyData)
        #expect(try await reopened.commitments(includingClosed: true).count == legacyValues.count)
        #expect(try await reopened.followUpSubject(id: "roadsight")?.name == "RoadSight")
    }

    @Test("The pre-optimization encrypted schema keeps observations, Journal, Actions, and conversations")
    func fullLegacyEncryptedDatabaseMigration() async throws {
        let directory = temporaryDirectory(named: "FullLegacy")
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date()
        let observation = Observation(
            source: .screen,
            capturedAt: now.addingTimeInterval(-60),
            expiresAt: now.addingTimeInterval(3_600),
            applicationName: "Legacy Browser",
            windowTitle: "Migration fixture",
            text: "Legacy OCR that must survive migration."
        )
        let event = ActivityEvent(
            startedAt: now.addingTimeInterval(-120),
            endedAt: now.addingTimeInterval(-90),
            kind: .document,
            status: .observed,
            importance: .normal,
            title: "Legacy Journal event",
            summary: "Preserve this event across the optimization schema migration.",
            languageTag: "en-US",
            confidence: 0.91,
            createdAt: now.addingTimeInterval(-120),
            updatedAt: now.addingTimeInterval(-90)
        )
        let commitment = Commitment(
            eventID: event.id,
            owner: "You",
            action: "Preserve the legacy Action",
            contextLabel: "Migration",
            confidence: 0.88,
            state: .needsAttention,
            createdAt: now.addingTimeInterval(-80),
            updatedAt: now.addingTimeInterval(-80)
        )
        let conversation = AssistantConversation(
            title: "Legacy Ask conversation",
            answers: [AssistantAnswer(
                question: "Was the legacy data preserved?",
                text: "Yes, after a successful migration.",
                citations: [],
                createdAt: now.addingTimeInterval(-70)
            )],
            createdAt: now.addingTimeInterval(-70),
            updatedAt: now.addingTimeInterval(-70)
        )
        try writeFullLegacyEncryptedDatabase(
            directory: directory,
            observation: observation,
            event: event,
            commitment: commitment,
            conversation: conversation
        )

        do {
            let migrated = try EncryptedSQLiteStore(directory: directory, keyData: keyData)
            #expect(try await migrated.observation(id: observation.id)?.text == observation.text)
            #expect(try await migrated.event(id: event.id)?.title == event.title)
            #expect(try await migrated.event(id: event.id)?.summary == event.summary)
            #expect(try await migrated.commitments(includingClosed: true).contains { $0.id == commitment.id })
            #expect(try await migrated.assistantConversations(limit: 10).first?.id == conversation.id)
        }

        // Schema additions are persisted by initialization itself, even before
        // an application-level write occurs.
        let reopened = try EncryptedSQLiteStore(directory: directory, keyData: keyData)
        #expect(try await reopened.observation(id: observation.id)?.text == observation.text)
        #expect(try await reopened.event(id: event.id)?.title == event.title)
        #expect(try await reopened.commitments(includingClosed: true).contains { $0.id == commitment.id })
        #expect(try await reopened.assistantConversations(limit: 10).first?.title == conversation.title)
        let jobs = try await reopened.claimAnalysisJobs(limit: 10, now: now)
        #expect(jobs.map(\.observationID) == [observation.id])
    }

    private func temporaryDirectory(named suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("IrizFollowUpPersistence-\(suffix)-\(UUID())", isDirectory: true)
    }

    private func makeEvent(title: String) -> ActivityEvent {
        ActivityEvent(
            startedAt: Date(),
            endedAt: Date(),
            kind: .task,
            status: .inProgress,
            importance: .normal,
            title: title,
            summary: title,
            confidence: 0.9
        )
    }

    private func makeCommitment(eventID: UUID, action: String) -> Commitment {
        Commitment(
            eventID: eventID,
            owner: "You",
            action: action,
            confidence: 0.9,
            state: .needsAttention,
            lifecycle: .active,
            aiPriorityScore: 7
        )
    }

    private func legacyPayload(for commitment: Commitment) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let encoded = try encoder.encode(commitment)
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let modernKeys = [
            "summary", "details", "lifecycle", "subjectID", "area", "origin", "detailLevelAtCreation", "aiPriorityScore",
            "userPriorityScore", "priorityReason", "surfacedAt", "snoozedUntil", "completedAt",
            "dismissedAt", "completionActor", "completionEvidence", "dueSource", "dueConfidence",
            "evidenceHint", "manuallyEditedFields", "history"
        ]
        for key in modernKeys { object.removeValue(forKey: key) }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func writeLegacyEncryptedDatabase(directory: URL, commitments: [Commitment]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let plaintextURL = directory.appendingPathComponent("legacy.sqlite")
        var database: OpaquePointer?
        let openCode = sqlite3_open_v2(
            plaintextURL.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openCode == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw SQLiteStoreError.openFailed("Unable to create legacy fixture")
        }
        var shouldCloseDatabase = true
        defer {
            if shouldCloseDatabase { sqlite3_close(database) }
        }

        try executeLegacySQL(
            """
            CREATE TABLE commitments (
                id TEXT PRIMARY KEY NOT NULL,
                event_id TEXT NOT NULL,
                state TEXT NOT NULL,
                review_at REAL,
                confidence REAL NOT NULL,
                payload BLOB NOT NULL
            );
            """,
            on: database
        )

        for commitment in commitments {
            let payload = try legacyPayload(for: commitment)
            var statement: OpaquePointer?
            let prepareCode = sqlite3_prepare_v2(
                database,
                "INSERT INTO commitments (id, event_id, state, review_at, confidence, payload) VALUES (?, ?, ?, ?, ?, ?)",
                -1,
                &statement,
                nil
            )
            guard prepareCode == SQLITE_OK, let statement else {
                throw SQLiteStoreError.sqlite(
                    code: prepareCode,
                    message: String(cString: sqlite3_errmsg(database)),
                    sql: "legacy commitment insert"
                )
            }
            defer { sqlite3_finalize(statement) }

            let idBindCode = commitment.id.uuidString.withCString {
                sqlite3_bind_text(statement, 1, $0, -1, sqliteTransient)
            }
            let eventBindCode = commitment.eventID.uuidString.withCString {
                sqlite3_bind_text(statement, 2, $0, -1, sqliteTransient)
            }
            let stateBindCode = commitment.state.rawValue.withCString {
                sqlite3_bind_text(statement, 3, $0, -1, sqliteTransient)
            }
            if let reviewAt = commitment.explicitDueAt ?? commitment.suggestedReviewAt {
                sqlite3_bind_double(statement, 4, reviewAt.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(statement, 4)
            }
            sqlite3_bind_double(statement, 5, commitment.confidence)
            let bindCode = payload.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, 6, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
            }
            guard idBindCode == SQLITE_OK,
                  eventBindCode == SQLITE_OK,
                  stateBindCode == SQLITE_OK,
                  bindCode == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_DONE else {
                throw SQLiteStoreError.sqlite(
                    code: sqlite3_errcode(database),
                    message: String(cString: sqlite3_errmsg(database)),
                    sql: "legacy commitment insert"
                )
            }
        }

        let closeCode = sqlite3_close(database)
        guard closeCode == SQLITE_OK else {
            throw SQLiteStoreError.sqlite(
                code: closeCode,
                message: String(cString: sqlite3_errmsg(database)),
                sql: "close legacy fixture"
            )
        }
        shouldCloseDatabase = false

        let plaintext = try Data(contentsOf: plaintextURL)
        let encrypted = try CryptoBox(keyData: keyData).seal(
            plaintext,
            authenticating: Data("IrizSQLiteV1".utf8)
        )
        try EncryptedFileWriter.write(
            encrypted,
            to: directory.appendingPathComponent("Iriz.sqlite.iriz")
        )
        try FileManager.default.removeItem(at: plaintextURL)
    }

    private func writeFullLegacyEncryptedDatabase(
        directory: URL,
        observation: Observation,
        event: ActivityEvent,
        commitment: Commitment,
        conversation: AssistantConversation
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let plaintextURL = directory.appendingPathComponent("legacy-full.sqlite")
        var database: OpaquePointer?
        let openCode = sqlite3_open_v2(
            plaintextURL.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openCode == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw SQLiteStoreError.openFailed("Unable to create full legacy fixture")
        }
        var shouldCloseDatabase = true
        defer {
            if shouldCloseDatabase { sqlite3_close(database) }
        }

        try executeLegacySQL(
            """
            PRAGMA foreign_keys = ON;
            CREATE TABLE events (
                id TEXT PRIMARY KEY NOT NULL,
                started_at REAL NOT NULL,
                ended_at REAL NOT NULL,
                importance INTEGER NOT NULL,
                status TEXT NOT NULL,
                kind TEXT NOT NULL,
                language TEXT NOT NULL,
                payload BLOB NOT NULL
            );
            CREATE VIRTUAL TABLE event_fts USING fts5(
                id UNINDEXED, title, summary, details, entities, urls, applications,
                tokenize = 'unicode61 remove_diacritics 2'
            );
            CREATE TABLE observations (
                id TEXT PRIMARY KEY NOT NULL,
                captured_at REAL NOT NULL,
                expires_at REAL NOT NULL,
                source TEXT NOT NULL,
                processed_at REAL,
                payload BLOB NOT NULL
            );
            CREATE TABLE commitments (
                id TEXT PRIMARY KEY NOT NULL,
                event_id TEXT NOT NULL REFERENCES events(id) ON DELETE CASCADE,
                state TEXT NOT NULL,
                review_at REAL,
                confidence REAL NOT NULL,
                payload BLOB NOT NULL
            );
            CREATE TABLE assistant_conversations (
                id TEXT PRIMARY KEY NOT NULL,
                updated_at REAL NOT NULL,
                payload BLOB NOT NULL
            );
            """,
            on: database
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        try insertLegacyRow(
            "INSERT INTO events (id, started_at, ended_at, importance, status, kind, language, payload) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            values: [
                .text(event.id.uuidString),
                .double(event.startedAt.timeIntervalSince1970),
                .double(event.endedAt.timeIntervalSince1970),
                .integer(Int64(event.importance.rawValue)),
                .text(event.status.rawValue),
                .text(event.kind.rawValue),
                .text(event.languageTag),
                .blob(try encoder.encode(event))
            ],
            on: database
        )
        try insertLegacyRow(
            "INSERT INTO event_fts (id, title, summary, details, entities, urls, applications) VALUES (?, ?, ?, ?, ?, ?, ?)",
            values: [
                .text(event.id.uuidString), .text(event.title), .text(event.summary), .text(event.details),
                .text(event.entities.joined(separator: " ")),
                .text(event.urls.map(\.absoluteString).joined(separator: " ")),
                .text(event.sourceApplications.joined(separator: " "))
            ],
            on: database
        )
        try insertLegacyRow(
            "INSERT INTO observations (id, captured_at, expires_at, source, processed_at, payload) VALUES (?, ?, ?, ?, ?, ?)",
            values: [
                .text(observation.id.uuidString),
                .double(observation.capturedAt.timeIntervalSince1970),
                .double(observation.expiresAt.timeIntervalSince1970),
                .text(observation.source.rawValue),
                .null,
                .blob(try encoder.encode(observation))
            ],
            on: database
        )
        try insertLegacyRow(
            "INSERT INTO commitments (id, event_id, state, review_at, confidence, payload) VALUES (?, ?, ?, ?, ?, ?)",
            values: [
                .text(commitment.id.uuidString),
                .text(commitment.eventID.uuidString),
                .text(commitment.state.rawValue),
                .null,
                .double(commitment.confidence),
                .blob(try legacyPayload(for: commitment))
            ],
            on: database
        )
        try insertLegacyRow(
            "INSERT INTO assistant_conversations (id, updated_at, payload) VALUES (?, ?, ?)",
            values: [
                .text(conversation.id.uuidString),
                .double(conversation.updatedAt.timeIntervalSince1970),
                .blob(try encoder.encode(conversation))
            ],
            on: database
        )

        let closeCode = sqlite3_close(database)
        guard closeCode == SQLITE_OK else {
            throw SQLiteStoreError.sqlite(
                code: closeCode,
                message: String(cString: sqlite3_errmsg(database)),
                sql: "close full legacy fixture"
            )
        }
        shouldCloseDatabase = false

        let plaintext = try Data(contentsOf: plaintextURL)
        let encrypted = try CryptoBox(keyData: keyData).seal(
            plaintext,
            authenticating: Data("IrizSQLiteV1".utf8)
        )
        try EncryptedFileWriter.write(
            encrypted,
            to: directory.appendingPathComponent("Iriz.sqlite.iriz")
        )
        try FileManager.default.removeItem(at: plaintextURL)
    }

    private enum LegacyBoundValue {
        case text(String)
        case integer(Int64)
        case double(Double)
        case blob(Data)
        case null
    }

    private func insertLegacyRow(
        _ sql: String,
        values: [LegacyBoundValue],
        on database: OpaquePointer
    ) throws {
        var statement: OpaquePointer?
        let prepareCode = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareCode == SQLITE_OK, let statement else {
            throw SQLiteStoreError.sqlite(
                code: prepareCode,
                message: String(cString: sqlite3_errmsg(database)),
                sql: sql
            )
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32 = switch value {
            case .text(let string):
                string.withCString { sqlite3_bind_text(statement, index, $0, -1, sqliteTransient) }
            case .integer(let integer):
                sqlite3_bind_int64(statement, index, integer)
            case .double(let double):
                sqlite3_bind_double(statement, index, double)
            case .blob(let data):
                data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
                }
            case .null:
                sqlite3_bind_null(statement, index)
            }
            guard code == SQLITE_OK else {
                throw SQLiteStoreError.sqlite(
                    code: code,
                    message: String(cString: sqlite3_errmsg(database)),
                    sql: sql
                )
            }
        }
        let stepCode = sqlite3_step(statement)
        guard stepCode == SQLITE_DONE else {
            throw SQLiteStoreError.sqlite(
                code: stepCode,
                message: String(cString: sqlite3_errmsg(database)),
                sql: sql
            )
        }
    }

    private func executeLegacySQL(_ sql: String, on database: OpaquePointer) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(database, sql, nil, nil, &errorPointer)
        guard code == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            if let errorPointer { sqlite3_free(errorPointer) }
            throw SQLiteStoreError.sqlite(code: code, message: message, sql: sql)
        }
    }

    private var sqliteTransient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

}
