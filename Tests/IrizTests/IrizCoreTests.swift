import CoreGraphics
import Foundation
import Testing
@testable import Iriz

@Suite("Iriz core")
struct IrizCoreTests {
    @Test("AES-GCM round trip rejects the wrong context")
    func cryptoRoundTrip() throws {
        let box = try CryptoBox(keyData: Data(repeating: 7, count: 32))
        let plain = Data("a private moment".utf8)
        let sealed = try box.seal(plain, authenticating: Data("journal".utf8))
        #expect(sealed != plain)
        #expect(try box.open(sealed, authenticating: Data("journal".utf8)) == plain)
        #expect(throws: CryptoBoxError.self) {
            try box.open(sealed, authenticating: Data("other".utf8))
        }
    }

    @Test("Encrypted journal supports full-text search without plaintext at rest")
    func encryptedJournalAndSearch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("IrizTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try EncryptedSQLiteStore(directory: directory, keyData: Data(repeating: 9, count: 32))
        let event = ActivityEvent(
            startedAt: Date(),
            endedAt: Date(),
            kind: .application,
            status: .completed,
            importance: .important,
            title: "Applied to RoadSight",
            summary: "Submitted an application for an automotive camera role.",
            entities: ["RoadSight", "trucks", "cameras"],
            urls: [URL(string: "https://roadsight.example/jobs/camera")!],
            confidence: 0.95
        )
        try await store.saveEvent(event)
        let matches = try await store.searchEvents(query: "truck camera", limit: 10)
        #expect(matches.map(\.id) == [event.id])
        let disk = try Data(contentsOf: directory.appendingPathComponent("Iriz.sqlite.iriz"))
        #expect(!String(decoding: disk, as: UTF8.self).contains("RoadSight"))
    }

    @Test("A viewed role is not a completed application")
    func applicationStates() {
        let viewed = Observation(
            source: .screen,
            applicationName: "Safari",
            url: URL(string: "https://example.com/jobs/driver"),
            text: "Job description — Apply now"
        )
        let submitted = Observation(
            source: .screen,
            applicationName: "Safari",
            url: URL(string: "https://example.com/jobs/driver/confirmation"),
            text: "Thank you for applying. We received your application."
        )
        #expect(HeuristicInterpreter.interpret(viewed).event?.status == .observed)
        #expect(HeuristicInterpreter.interpret(submitted).event?.status == .completed)
    }

    @Test("Checkout is distinct from a confirmed purchase")
    func purchaseStates() {
        let checkout = Observation(source: .screen, text: "Checkout — review your order and payment")
        let confirmed = Observation(source: .screen, text: "Order confirmed. Order number 1942")
        #expect(HeuristicInterpreter.interpret(checkout).event?.status == .inProgress)
        #expect(HeuristicInterpreter.interpret(confirmed).event?.status == .completed)
    }

    @Test("Capsule modes match the screen and microphone configuration")
    func observationModes() {
        var settings = IrizSettings()
        #expect(ObservationMode.current(for: settings) == .paused)

        settings.isPaused = false
        settings.screenCaptureEnabled = true
        settings.audioMode = .off
        #expect(ObservationMode.current(for: settings) == .observe)

        settings.screenCaptureEnabled = false
        settings.audioMode = .alwaysOn
        #expect(ObservationMode.current(for: settings) == .listen)

        settings.screenCaptureEnabled = true
        #expect(ObservationMode.current(for: settings) == .observeAndListen)

        settings.audioMode = .schedule
        #expect(ObservationMode.current(for: settings) == .schedule)
    }

    @Test("Observe and Listen share one configuration with Pause as master override")
    func sharedObservationChannels() {
        var settings = IrizSettings()
        settings.isPaused = false
        settings.setListenEnabled(true)
        #expect(settings.screenCaptureEnabled)
        #expect(settings.audioMode == .alwaysOn)
        #expect(!settings.isPaused)

        settings.isPaused = true
        settings.setListeningBehavior(.schedule)
        #expect(settings.audioMode == .schedule)
        #expect(settings.isPaused)

        settings.setObserveEnabled(false)
        settings.setListenEnabled(false)
        #expect(!settings.screenCaptureEnabled)
        #expect(settings.audioMode == .off)
        #expect(settings.isPaused)
    }

    @Test("Screen capture never retries while permission is inactive")
    func screenCapturePermissionGate() {
        var settings = IrizSettings()
        settings.isPaused = false
        settings.screenCaptureEnabled = true
        #expect(!ScreenCaptureService.shouldAttemptCapture(settings: settings, permission: .notDetermined))
        #expect(!ScreenCaptureService.shouldAttemptCapture(settings: settings, permission: .denied))
        #expect(ScreenCaptureService.shouldAttemptCapture(settings: settings, permission: .granted))
    }

    @Test("Permission status distinguishes never requested from denied")
    func permissionStatusInference() {
        #expect(PermissionService.inferredState(isGranted: true, wasRequested: false) == .granted)
        #expect(PermissionService.inferredState(isGranted: false, wasRequested: false) == .notDetermined)
        #expect(PermissionService.inferredState(isGranted: false, wasRequested: true) == .denied)
    }

    @Test("Keychain approval states never expose destructive actions")
    func keychainApprovalState() {
        #expect(APIKeyState.checking.canRemove == false)
        #expect(APIKeyState.needsApproval.canRemove == false)
        #expect(APIKeyState.saved.canRemove)
    }

    @Test("Silence produces no upload and natural silence closes speech")
    func voiceActivityDetection() {
        var segmenter = SpeechSegmenter()
        var silenceResults: [SpeechSegment] = []
        for _ in 0..<150 {
            silenceResults += segmenter.process(samples: [Float](repeating: 0, count: 480), sampleRate: 48_000)
        }
        #expect(silenceResults.isEmpty)

        var results: [SpeechSegment] = []
        for _ in 0..<50 {
            results += segmenter.process(samples: [Float](repeating: 0.08, count: 480), sampleRate: 48_000)
        }
        for _ in 0..<130 {
            results += segmenter.process(samples: [Float](repeating: 0, count: 480), sampleRate: 48_000)
        }
        #expect(results.count == 1)
        #expect((results.first?.voicedDuration ?? 0) >= 0.49)
    }

    @Test("OpenAI analysis uses the planned model, strict output and no storage")
    func openAIRequestSafety() throws {
        let observation = Observation(source: .screen, applicationName: "Safari", text: "Application submitted")
        let data = try OpenAIRequestFactory.interpretationRequest(
            observation: observation,
            imageData: Data([1, 2, 3]),
            outputLanguage: "French"
        )
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["model"] as? String == OpenAIModelPolicy.frequentAnalysis)
        #expect(json["store"] as? Bool == false)
        let text = try #require(json["text"] as? [String: Any])
        let format = try #require(text["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect(format["strict"] as? Bool == true)
    }

    @Test("Diarized transcription labels the enrolled user and uses automatic chunking")
    func diarizedRequest() {
        let body = OpenAIRequestFactory.transcriptionRequest(
            wavData: Data([1, 2, 3]),
            boundary: "Boundary",
            model: OpenAIModelPolicy.diarizedTranscription,
            languageTag: "fr-FR",
            knownSpeakerReference: Data([4, 5, 6])
        )
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains("diarized_json"))
        #expect(text.contains("chunking_strategy"))
        #expect(text.contains("known_speaker_names[]"))
        #expect(text.contains("You"))
        #expect(text.contains("data:audio/wav;base64,"))
    }

    @Test("Selected speech language guides simple and diarized transcription")
    func transcriptionLanguageHints() {
        let simple = OpenAIRequestFactory.transcriptionRequest(
            wavData: Data([1]),
            boundary: "SimpleBoundary",
            model: OpenAIModelPolicy.transcription,
            languageTag: "he-IL",
            knownSpeakerReference: nil
        )
        let meeting = OpenAIRequestFactory.transcriptionRequest(
            wavData: Data([1]),
            boundary: "MeetingBoundary",
            model: OpenAIModelPolicy.diarizedTranscription,
            languageTag: "he-IL",
            knownSpeakerReference: nil
        )
        let simpleText = String(decoding: simple, as: UTF8.self)
        let meetingText = String(decoding: meeting, as: UTF8.self)
        #expect(simpleText.contains("name=\"languages[]\""))
        #expect(simpleText.contains("\r\n\r\nhe\r\n"))
        #expect(meetingText.contains("name=\"language\""))
        #expect(meetingText.contains("\r\n\r\nhe\r\n"))
    }

    @MainActor
    @Test("Selected language is a strong journal and voice hint")
    func languagePromptGuidance() {
        let suiteName = "IrizLanguageTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)
        store.settings.outputLanguageTag = "he-IL"
        let prompt = store.outputLanguagePrompt()
        #expect(prompt.contains("he-IL"))
        #expect(prompt.contains("usual language"))
        #expect(prompt.contains("meetings"))
        #expect(prompt.contains("voice sessions"))
    }

    @Test("Relative day questions use the exact local calendar day")
    func relativeDayFilter() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 15)))
        let parsed = QueryUnderstanding.parse("What did I apply to 3 days ago?", now: now, calendar: calendar)
        let start = try #require(parsed.dateInterval?.start)
        #expect(calendar.component(.day, from: start) == 7)
        let duration = try #require(parsed.dateInterval?.duration)
        #expect(abs(duration - 86_400) < 0.001)
    }

    @Test("Voice enrollment clips a reference WAV to ten seconds")
    func voiceReferenceCap() {
        let segment = SpeechSegment(samples: [Float](repeating: 0.1, count: 48_000 * 12), sampleRate: 48_000, voicedDuration: 12)
        let capped = WAVEncoder.cappedForVoiceReference(WAVEncoder.encode(segment))
        #expect(capped.count == 44 + 48_000 * 2 * 10)
    }

    @Test("Later completed evidence can close a matching promise")
    func commitmentEvidenceLinking() throws {
        let created = Date().addingTimeInterval(-300)
        let sourceEvent = UUID()
        let commitment = Commitment(
            eventID: sourceEvent,
            owner: "You",
            action: "Send the camera specification document to Morgan",
            confidence: 0.9,
            state: .needsAttention,
            createdAt: created,
            updatedAt: created
        )
        let evidence = ActivityEvent(
            startedAt: Date(),
            endedAt: Date(),
            kind: .document,
            status: .completed,
            importance: .important,
            title: "Camera specification sent to Morgan",
            summary: "The camera specification document was sent to Morgan.",
            confidence: 0.94
        )
        let linked = try #require(CommitmentLinker.linking(commitment, to: evidence))
        #expect(linked.state == .completed)
        #expect(linked.linkedEventIDs == [evidence.id])
        #expect(linked.rationale.contains("Matching evidence"))
    }

    @Test("Expired raw observations and structured retention are enforced")
    func retention() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("IrizRetention-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try EncryptedSQLiteStore(directory: directory, keyData: Data(repeating: 3, count: 32))
        let old = Date().addingTimeInterval(-100 * 24 * 60 * 60)
        let event = ActivityEvent(startedAt: old, endedAt: old, kind: .note, status: .completed, importance: .normal, title: "Old", summary: "Old", confidence: 1)
        let observation = Observation(source: .screen, capturedAt: old, expiresAt: old, text: "expired")
        try await store.saveEvent(event)
        try await store.saveObservation(observation)
        try await store.purgeExpired(now: Date(), retention: .ninetyDays)
        #expect(try await store.eventCount() == 0)
        #expect(try await store.observation(id: observation.id) == nil)
    }

    @Test("Expired encrypted media is physically removed")
    func mediaExpiry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("IrizMedia-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = try EncryptedMediaStore(directory: directory, keyData: Data(repeating: 5, count: 32))
        let identifier = try await media.store(Data("private audio".utf8), fileExtension: "wav", expiresAt: Date().addingTimeInterval(-1))
        #expect(try await media.read(identifier: identifier) == Data("private audio".utf8))
        #expect(try await media.purgeExpired(now: Date()) == 1)
        await #expect(throws: EncryptedMediaStore.MediaError.self) {
            try await media.read(identifier: identifier)
        }
    }

    @Test("Exports never retain an expired media identifier")
    func exportDropsExpiredMedia() throws {
        let observationID = UUID()
        let event = ActivityEvent(
            startedAt: Date(),
            endedAt: Date(),
            kind: .note,
            status: .completed,
            importance: .important,
            title: "Private event",
            summary: "Useful summary",
            confidence: 1,
            evidence: [EvidenceReference(
                observationID: observationID,
                source: .screen,
                capturedAt: Date(),
                expiresAt: Date().addingTimeInterval(-1),
                mediaIdentifier: "expired-secret.jpg.iriz"
            )]
        )
        let data = try ExportService.render(events: [event], commitments: [], format: .json)
        #expect(!String(decoding: data, as: UTF8.self).contains("expired-secret"))
    }
}
