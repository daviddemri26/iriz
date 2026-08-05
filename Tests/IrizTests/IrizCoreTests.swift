import CoreGraphics
import Foundation
import Testing
@testable import Iriz

@Suite("Iriz core")
struct IrizCoreTests {
    @Test("Build channels distinguish development from stable permission testing")
    func buildChannelResolution() {
        #expect(
            IrizBuildChannel.resolve(
                infoDictionary: ["IrizBuildChannel": "ReleaseCandidate"],
                isDebug: false
            ) == .releaseCandidate
        )
        #expect(
            IrizBuildChannel.resolve(
                infoDictionary: ["IrizBuildChannel": "Standalone"],
                isDebug: false
            ) == .standalone
        )
        #expect(IrizBuildChannel.resolve(infoDictionary: [:], isDebug: false) == .development)
        #expect(
            IrizBuildChannel.resolve(
                infoDictionary: ["IrizBuildChannel": "Standalone"],
                isDebug: true
            ) == .development
        )
    }

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

    @Test("Assistant conversations persist locally inside the encrypted journal")
    func encryptedAssistantConversations() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("IrizConversationTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try EncryptedSQLiteStore(directory: directory, keyData: Data(repeating: 8, count: 32))
        let answer = AssistantAnswer(
            question: "Which hotel did I research?",
            text: "You researched **Hotel Lumière**.",
            citations: []
        )
        let conversation = AssistantConversation(
            title: "Paris hotel research",
            answers: [answer],
            pinnedAt: Date(timeIntervalSince1970: 100)
        )

        try await store.saveAssistantConversation(conversation)
        let restored = try await store.assistantConversations(limit: 10)
        #expect(restored.first?.id == conversation.id)
        #expect(restored.first?.answers.first?.text == answer.text)
        #expect(restored.first?.pinnedAt == conversation.pinnedAt)

        let disk = try Data(contentsOf: directory.appendingPathComponent("Iriz.sqlite.iriz"))
        #expect(!String(decoding: disk, as: UTF8.self).contains("Hotel Lumière"))

        try await store.deleteAssistantConversation(id: conversation.id)
        #expect(try await store.assistantConversations(limit: 10).isEmpty)
    }

    @Test("Pinned conversations are ordered by the latest explicit pin")
    func pinnedAssistantConversations() {
        let earlier = AssistantConversation(
            title: "Earlier pin",
            pinnedAt: Date(timeIntervalSince1970: 100)
        )
        let unpinned = AssistantConversation(title: "Not pinned")
        let later = AssistantConversation(
            title: "Later pin",
            pinnedAt: Date(timeIntervalSince1970: 200)
        )

        let pinned = AssistantConversationPinning.pinned(from: [earlier, unpinned, later])
        #expect(pinned.map(\.id) == [later.id, earlier.id])

        let removed = AssistantConversationPinning.updating(later, isPinned: false)
        #expect(removed.pinnedAt == nil)
        #expect(removed.updatedAt == later.updatedAt)
    }

    @Test("Older conversation payloads decode as unpinned")
    func legacyAssistantConversationPinning() throws {
        struct LegacyConversation: Encodable {
            let id: UUID
            let title: String
            let answers: [AssistantAnswer]
            let createdAt: Date
            let updatedAt: Date
        }

        let legacy = LegacyConversation(
            id: UUID(),
            title: "Legacy conversation",
            answers: [],
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(AssistantConversation.self, from: data)

        #expect(decoded.id == legacy.id)
        #expect(decoded.pinnedAt == nil)
    }

    @Test("Conversation titles are concise and derived locally")
    func assistantConversationTitles() {
        let title = AssistantConversation.title(for: "  What were the important decisions from my customer meetings this week and what should I do next?  ")
        #expect(title.hasPrefix("What were the important decisions"))
        #expect(title.hasSuffix("…"))
        #expect(title.count <= 55)
    }

    @Test("Assistant Markdown preserves block structure and hard line breaks")
    func assistantMarkdownDocument() {
        let document = AssistantMarkdownDocument(markdown: """
        Intro line.
        Second line.

        ## Decision

        - Keep the paragraph break
        - Preserve **bold** text

        1. First step
        2. Second step

        > A quoted note

        ```json
        {"ready":true}
        ```
        """)

        #expect(document.blocks == [
            .paragraph("Intro line.\nSecond line."),
            .heading(level: 2, text: "Decision"),
            .unorderedList(["Keep the paragraph break", "Preserve **bold** text"]),
            .orderedList([
                .init(number: 1, text: "First step"),
                .init(number: 2, text: "Second step")
            ]),
            .quote("A quoted note"),
            .code("{\"ready\":true}")
        ])
    }

    @Test("How Iriz Works is the initial main section")
    func initialMainSection() {
        #expect(MainSection.initial == .howIrizWorks)
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

        settings.audioMode = .alwaysOn
        settings.captureTiming = .schedule
        settings.audioSchedule.weekdays = []
        #expect(ObservationMode.current(for: settings) == .schedule)
    }

    @Test("The control card reports current activity instead of the timing mode")
    func liveStatusSemantics() {
        let waiting = CaptureHealth.waitingForSchedule.irizAppearance
        #expect(waiting.title == "iriz is waiting")
        #expect(waiting.detail.contains("Not observing or listening"))
        #expect(!waiting.rotates)

        let observing = CaptureHealth.observing.irizAppearance
        #expect(observing.title == "iriz is observing")
        #expect(observing.detail.contains("right now"))
        #expect(!observing.rotates)
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
        #expect(settings.audioMode == .alwaysOn)
        #expect(settings.captureTiming == .schedule)
        #expect(settings.isPaused)

        settings.setObserveEnabled(false)
        settings.setListenEnabled(false)
        #expect(!settings.screenCaptureEnabled)
        #expect(settings.audioMode == .off)
        #expect(settings.isPaused)
    }

    @Test("One schedule gates both Observe and Listen")
    func sharedCaptureSchedule() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let inside = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 10)))
        let outside = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 20)))
        var settings = IrizSettings()
        settings.isPaused = false
        settings.screenCaptureEnabled = true
        settings.setListenEnabled(true)
        settings.captureTiming = .schedule
        settings.audioSchedule = AudioSchedule(startMinutes: 9 * 60, endMinutes: 18 * 60, weekdays: [2])

        #expect(settings.isCaptureWindowActive(at: inside, calendar: calendar))
        #expect(settings.isScreenCaptureActive(at: inside, calendar: calendar))
        #expect(settings.isAudioActive(at: inside, calendar: calendar))
        #expect(!settings.isScreenCaptureActive(at: outside, calendar: calendar))
        #expect(!settings.isAudioActive(at: outside, calendar: calendar))
    }

    @Test("Legacy microphone schedules migrate to the shared capture schedule")
    func legacyScheduleMigration() throws {
        let legacy = Data(#"{"audioMode":"schedule","audioSchedule":{"startMinutes":540,"endMinutes":1080,"weekdays":[2,3,4,5,6]}}"#.utf8)
        let settings = try JSONDecoder().decode(IrizSettings.self, from: legacy)
        #expect(settings.audioMode == .alwaysOn)
        #expect(settings.captureTiming == .schedule)
        #expect(settings.followUpDetailLevel == .standard)
        #expect(settings.showMenuBarItem)
        #expect(settings.showFloatingBubble)
    }

    @Test("An overnight schedule follows the selected starting day")
    func overnightSchedule() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let mondayLate = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 23)))
        let tuesdayEarly = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 4, hour: 1)))
        let tuesdayLate = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 4, hour: 3)))
        let schedule = AudioSchedule(startMinutes: 22 * 60, endMinutes: 2 * 60, weekdays: [2])
        #expect(schedule.isActive(at: mondayLate, calendar: calendar))
        #expect(schedule.isActive(at: tuesdayEarly, calendar: calendar))
        #expect(!schedule.isActive(at: tuesdayLate, calendar: calendar))
    }

    @Test("Screen capture never retries while permission is inactive")
    func screenCapturePermissionGate() {
        var settings = IrizSettings()
        settings.isPaused = false
        settings.screenCaptureEnabled = true
        #expect(!ScreenCaptureService.shouldAttemptCapture(settings: settings, permission: .notDetermined))
        #expect(!ScreenCaptureService.shouldAttemptCapture(settings: settings, permission: .denied))
        #expect(ScreenCaptureService.shouldAttemptCapture(settings: settings, permission: .granted))
        #expect(!ScreenCaptureService.shouldAttemptCapture(
            settings: settings,
            permission: .granted,
            accessibilityPermission: .notDetermined
        ))
        #expect(!ScreenCaptureService.shouldAttemptCapture(
            settings: settings,
            permission: .granted,
            accessibilityPermission: .denied
        ))
        #expect(ScreenCaptureService.shouldAttemptCapture(
            settings: settings,
            permission: .granted,
            accessibilityPermission: .granted
        ))
    }

    @Test("Accessibility context never inspects Iriz or excluded applications")
    func activeContextEarlyExclusion() {
        let excluded: Set<String> = ["com.1password.1password"]
        #expect(!ActiveContextService.shouldInspect(
            bundleIdentifier: "com.iriz.memory",
            ownBundleIdentifier: "com.iriz.memory",
            excludedBundleIdentifiers: excluded
        ))
        #expect(!ActiveContextService.shouldInspect(
            bundleIdentifier: "com.1password.1password",
            ownBundleIdentifier: "com.iriz.memory",
            excludedBundleIdentifiers: excluded
        ))
        #expect(ActiveContextService.shouldInspect(
            bundleIdentifier: "com.apple.Safari",
            ownBundleIdentifier: "com.iriz.memory",
            excludedBundleIdentifiers: excluded
        ))
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
        let reasoning = try #require(json["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == "none")
    }

    @Test("Cloud follow-up requests expose only raw AI priority")
    func cloudFollowUpPriorityPrivacy() throws {
        let commitment = Commitment(
            eventID: UUID(),
            owner: "You",
            action: "Send the client proposal",
            contextLabel: "Client Acme",
            confidence: 0.9,
            state: .needsAttention,
            area: .work,
            aiPriorityScore: 3,
            displayPriorityScore: 8,
            userPriorityScore: 10,
            manuallyEditedFields: [.priority]
        )
        let observationData = try OpenAIRequestFactory.interpretationRequest(
            observation: Observation(source: .screen, text: "Acme proposal notes"),
            imageData: nil,
            outputLanguage: "English",
            followUpCandidates: [commitment]
        )
        let observationObject = try #require(try JSONSerialization.jsonObject(with: observationData) as? [String: Any])
        let observationInput = try #require(observationObject["input"] as? [[String: Any]])
        let observationContent = try #require(observationInput.first?["content"] as? [[String: Any]])
        let observationPrompt = observationContent.compactMap { $0["text"] as? String }.joined(separator: "\n")

        #expect(observationPrompt.contains("\"priority\":3"))
        #expect(!observationPrompt.contains("\"priority\":10"))
        #expect(!observationPrompt.contains("priorityBias"))
        #expect(!observationPrompt.contains("manuallyEditedFields"))

        let mergeData = try OpenAIRequestFactory.followUpMergeRequest(
            commitments: [commitment],
            subject: FollowUpSubject(name: "Client Acme", area: .work, priorityBias: 3),
            outputLanguage: "English"
        )
        let mergeObject = try #require(try JSONSerialization.jsonObject(with: mergeData) as? [String: Any])
        let mergePrompt = try #require(mergeObject["input"] as? String)
        #expect(mergePrompt.contains("\"priority\":3"))
        #expect(!mergePrompt.contains("\"priority\":10"))
        #expect(!mergePrompt.contains("priorityBias"))
        #expect(!mergePrompt.contains("manuallyEditedFields"))
        #expect(mergePrompt.contains("relationship=unrelated"))
        #expect(mergeObject["store"] as? Bool == false)
    }

    @Test("Assistant requests include only recent thread context and disable storage")
    func assistantConversationContextRequest() throws {
        let previous = (0..<6).map { index in
            AssistantAnswer(
                question: "Previous question \(index)",
                text: "Previous answer \(index)",
                citations: []
            )
        }
        let data = try OpenAIRequestFactory.answerRequest(
            question: "And what happened next?",
            candidates: [],
            conversationContext: previous,
            outputLanguage: "English"
        )
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let input = try #require(json["input"] as? String)
        #expect(json["store"] as? Bool == false)
        #expect(!input.contains("Previous question 0"))
        #expect(!input.contains("Previous question 1"))
        #expect(input.contains("Previous question 2"))
        #expect(input.contains("Previous question 5"))
        #expect(input.contains("concise Markdown"))
        #expect(input.contains("Separate paragraphs, headings, and lists with blank lines"))
    }

    @Test("Observation guidance applies detail level only to newly created follow-ups")
    func scoredFollowUpPrompt() throws {
        let observation = Observation(source: .screen, text: "I should send the small receipt later")
        let existing = Commitment(
            eventID: UUID(),
            owner: "You",
            action: "Submit the final expense report",
            confidence: 0.9,
            state: .needsAttention,
            detailLevelAtCreation: .outcome
        )
        let data = try OpenAIRequestFactory.interpretationRequest(
            observation: observation,
            imageData: nil,
            outputLanguage: "English",
            followUpDetailLevel: .micro,
            followUpCandidates: [existing]
        )
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let input = try #require(object["input"] as? [[String: Any]])
        let content = try #require(input.first?["content"] as? [[String: Any]])
        let prompt = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        #expect(object["store"] as? Bool == false)
        #expect(prompt.contains("Detail level for newly created Actions: Micro"))
        #expect(prompt.contains("This setting applies only to operation=create"))
        #expect(prompt.contains("\"createdDetailLevel\":\"outcome\""))
        #expect(prompt.contains("priorityScore"))
        #expect(prompt.contains("at least 0.60"))
    }

    @Test("Observation guidance reuses stable dynamic follow-up contexts")
    func followUpContextPrompt() throws {
        let observation = Observation(source: .screen, text: "Book the hotel for our trip")
        let generic = FollowUpSubject(name: "Work", area: .work)
        let concrete = FollowUpSubject(name: "Lafayette Website", area: .work)
        let data = try OpenAIRequestFactory.interpretationRequest(
            observation: observation,
            imageData: nil,
            outputLanguage: "French",
            knownFollowUpContexts: ["Work", "Vacation with Léa"],
            knownFollowUpSubjects: [generic, concrete]
        )
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let input = try #require(object["input"] as? [[String: Any]])
        let content = try #require(input.first?["content"] as? [[String: Any]])
        let prompt = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        #expect(prompt.contains("area is only the broad Work, Personal, or Uncategorized type"))
        #expect(prompt.contains("contextLabel must be a concrete, reusable subject"))
        #expect(prompt.contains("Lafayette Website"))
        #expect(!prompt.contains("\"name\":\"Work\""))
    }

    @Test("Assistant model effort scales only for genuinely larger retrieval sets")
    func modelRoutingBudget() {
        let routine = OpenAIModelPolicy.assistantConfiguration(question: "Where did I apply?", candidateCount: 6)
        let complex = OpenAIModelPolicy.assistantConfiguration(question: "Compare the evidence", candidateCount: 18)
        #expect(routine.model == OpenAIModelPolicy.consolidation)
        #expect(routine.reasoningEffort == .low)
        #expect(complex.model == OpenAIModelPolicy.consolidation)
        #expect(complex.reasoningEffort == .medium)
        #expect(routine.maxOutputTokens < complex.maxOutputTokens)
    }

    @Test("Meaningful event refinement uses Terra at low effort without storage")
    func eventRefinementBudget() throws {
        let event = ActivityEvent(
            startedAt: Date(),
            endedAt: Date(),
            kind: .purchase,
            status: .completed,
            importance: .important,
            title: "Order confirmed",
            summary: "A purchase was confirmed.",
            urls: [URL(string: "https://example.com/order/42")!],
            confidence: 0.94
        )
        let data = try OpenAIRequestFactory.refinementRequest(event: event, outputLanguage: "English")
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["model"] as? String == OpenAIModelPolicy.consolidation)
        #expect(json["store"] as? Bool == false)
        let reasoning = try #require(json["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == "low")
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
        #expect(linked.rationale.contains("matching evidence"))
    }

    @Test("Moderate completion evidence proposes Done without asserting completion")
    func commitmentCompletionSuggestion() throws {
        let created = Date().addingTimeInterval(-300)
        let commitment = Commitment(
            eventID: UUID(),
            owner: "You",
            action: "Send the camera specification document to Morgan",
            confidence: 0.82,
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
            title: "Camera document delivered",
            summary: "Delivery completed.",
            confidence: 0.9
        )
        let linked = try #require(CommitmentLinker.linking(commitment, to: evidence))
        #expect(linked.state == .completionSuggested)
        #expect(linked.linkedEventIDs == [evidence.id])
        #expect(linked.rationale.contains("Possible completion evidence"))
    }

    @Test("Detail level never hides existing follow-up tiles")
    func followUpDetailLevelDoesNotFilterExistingTiles() {
        let event = ActivityEvent(
            startedAt: Date(),
            endedAt: Date(),
            kind: .note,
            status: .observed,
            importance: .normal,
            title: "Small task",
            summary: "A possible small task.",
            confidence: 0.7
        )
        let outcome = Commitment(
            eventID: event.id,
            owner: "You",
            action: "Finish the expense report",
            confidence: 0.55,
            state: .maybe,
            detailLevelAtCreation: .outcome
        )
        let micro = Commitment(
            eventID: event.id,
            owner: "You",
            action: "Attach the taxi receipt",
            confidence: 0.55,
            state: .maybe,
            detailLevelAtCreation: .micro
        )
        let ranked = FollowUpPrioritizer.ranked(commitments: [outcome, micro], events: [event])

        #expect(Set(ranked.map(\.id)) == Set([outcome.id, micro.id]))
    }

    @Test("Follow-ups keep broad types separate from concrete subjects")
    func dynamicFollowUpContexts() {
        let workEvent = ActivityEvent(
            startedAt: Date(), endedAt: Date(), kind: .application, status: .inProgress,
            importance: .important, title: "Camera role", summary: "Application follow-up", confidence: 0.9
        )
        let personalEvent = ActivityEvent(
            startedAt: Date(), endedAt: Date(), kind: .purchase, status: .inProgress,
            importance: .normal, title: "Household order", summary: "Personal order", confidence: 0.85
        )
        let tripEvent = ActivityEvent(
            startedAt: Date(), endedAt: Date(), kind: .appointment, status: .inProgress,
            importance: .important, title: "Hotel in Rome", summary: "Vacation planning", confidence: 0.9
        )
        let commitments = [
            Commitment(eventID: workEvent.id, owner: "You", action: "Reply to recruiter", contextLabel: "travail", confidence: 0.9, state: .needsAttention),
            Commitment(eventID: personalEvent.id, owner: "You", action: "Check delivery", contextLabel: "Personal", confidence: 0.85, state: .waiting),
            Commitment(eventID: tripEvent.id, owner: "You", action: "Book the hotel", contextLabel: "Vacation with Léa", confidence: 0.9, state: .later)
        ]
        let events = [workEvent, personalEvent, tripEvent]
        let ranked = FollowUpPrioritizer.ranked(commitments: commitments, events: events)
        let groups = FollowUpContextGrouper.groups(commitments: ranked, events: events)

        #expect(groups.map(\.label).contains("Applications"))
        #expect(groups.map(\.label).contains("Orders & Purchases"))
        #expect(groups.map(\.label).contains("Vacation with Léa"))
        #expect(!groups.map(\.label).contains("Work"))
        #expect(!groups.map(\.label).contains("Personal"))
        #expect(FollowUpContextGrouper.contextLabels(from: commitments) == ["Vacation with Léa"])
        #expect(commitments.map(\.area) == [.work, .personal, .personal])
    }

    @Test("Older Follow Up display preferences default new color filters safely")
    func legacyFollowUpDisplayPreferences() throws {
        let legacy = Data("""
        {
          "selectedArea": "work",
          "selectedSubjectIDs": ["lafayette-website"],
          "minimumPriority": 14,
          "viewMode": "active",
          "completedRailMode": "rail",
          "completedRailDuration": "oneDay"
        }
        """.utf8)
        let preferences = try JSONDecoder().decode(FollowUpDisplayPreferences.self, from: legacy)
        #expect(preferences.selectedColorTokens.isEmpty)
        #expect(preferences.selectedTypeIDs.isEmpty)
        #expect(preferences.minimumPriority == 10)
        #expect(preferences.selectedSubjectIDs == ["lafayette-website"])
    }

    @Test("Older encrypted commitments decode without newer optional metadata")
    func legacyCommitmentContextDecoding() throws {
        let commitment = Commitment(
            eventID: UUID(), owner: "You", action: "Review the document",
            contextLabel: "Work", confidence: 0.8, state: .later
        )
        let encoded = try JSONEncoder().encode(commitment)
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "contextLabel")
        object.removeValue(forKey: "isPriority")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Commitment.self, from: legacyData)

        #expect(decoded.id == commitment.id)
        #expect(decoded.contextLabel == nil)
        #expect(!decoded.isPriority)
    }

    @Test("Manual priority stays visible and ranks ahead of automatic follow-ups")
    func manualFollowUpPriority() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let event = ActivityEvent(
            startedAt: now, endedAt: now, kind: .note, status: .observed,
            importance: .background, title: "Small note", summary: "A small note", confidence: 0.4
        )
        let manual = Commitment(
            eventID: event.id, owner: "You", action: "Keep this visible",
            isPriority: true, confidence: 0.2, state: .maybe
        )
        let automatic = Commitment(
            eventID: event.id, owner: "You", action: "Automatic follow-up",
            explicitDueAt: now.addingTimeInterval(-86_400), confidence: 0.99, state: .needsAttention
        )

        let ranked = FollowUpPrioritizer.ranked(
            commitments: [automatic, manual], events: [event], now: now
        )

        #expect(ranked.first?.id == manual.id)
        #expect(ranked.first?.reason == "Marked as priority")
    }

    @Test("Repeated observations merge the same follow-up instead of duplicating it")
    func commitmentDeduplication() throws {
        let original = Commitment(
            eventID: UUID(),
            owner: "You",
            action: "Send the camera specification document to Morgan",
            suggestedReviewAt: Date().addingTimeInterval(3 * 86_400),
            confidence: 0.78,
            state: .later
        )
        let repeated = Commitment(
            eventID: UUID(),
            owner: "You",
            action: "Send camera specification document to Morgan",
            suggestedReviewAt: Date().addingTimeInterval(2 * 86_400),
            confidence: 0.9,
            state: .needsAttention
        )
        let merged = try #require(CommitmentLinker.mergingDuplicate(repeated, into: [original]))
        #expect(merged.id == original.id)
        #expect(merged.state == .needsAttention)
        #expect(merged.confidence == 0.9)
        #expect(merged.linkedEventIDs.contains(repeated.eventID))
    }

    @Test("Follow-ups promote overdue reviews and retain every item when the list grows")
    func followUpPrioritization() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let event = ActivityEvent(
            startedAt: now.addingTimeInterval(-3_600),
            endedAt: now.addingTimeInterval(-3_600),
            kind: .application,
            status: .inProgress,
            importance: .critical,
            title: "Application",
            summary: "Application follow-up",
            confidence: 0.95
        )
        let overdue = Commitment(
            eventID: event.id,
            owner: "You",
            action: "Send the requested portfolio",
            explicitDueAt: now.addingTimeInterval(-86_400),
            confidence: 0.95,
            state: .later
        )
        var commitments = [overdue]
        commitments += (0..<9).map { index in
            Commitment(
                eventID: event.id,
                owner: "You",
                action: "Review item \(index)",
                suggestedReviewAt: now.addingTimeInterval(Double(index + 2) * 86_400),
                confidence: 0.6,
                state: index.isMultiple(of: 2) ? .later : .waiting
            )
        }

        let sections = FollowUpPrioritizer.sections(
            commitments: commitments,
            events: [event],
            now: now
        )
        let ranked = sections.flatMap(\.commitments)
        #expect(sections.first?.state == .needsAttention)
        #expect(sections.first?.commitments.first?.id == overdue.id)
        #expect(ranked.count == commitments.count)
        #expect(ranked.filter(\.isHighlighted).count == FollowUpPrioritizer.highlightedLimit)
    }

    @Test("Expired raw observations and structured retention are enforced")
    func retention() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("IrizRetention-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try EncryptedSQLiteStore(directory: directory, keyData: Data(repeating: 3, count: 32))
        let old = Date().addingTimeInterval(-100 * 24 * 60 * 60)
        let event = ActivityEvent(startedAt: old, endedAt: old, kind: .note, status: .completed, importance: .normal, title: "Old", summary: "Old", confidence: 1)
        let observation = Observation(source: .screen, capturedAt: old, expiresAt: old, text: "expired")
        let completedFollowUp = Commitment(
            eventID: event.id,
            owner: "David",
            action: "Old completed follow-up",
            confidence: 1,
            state: .completed,
            createdAt: old,
            updatedAt: old,
            lifecycle: .completed,
            completedAt: old,
            completionActor: .user
        )
        try await store.saveEvent(event)
        try await store.saveObservation(observation)
        try await store.saveCommitment(completedFollowUp)
        try await store.purgeExpired(now: Date(), retention: .ninetyDays)
        #expect(try await store.eventCount() == 0)
        #expect(try await store.observation(id: observation.id) == nil)
        #expect(try await store.commitments(includingClosed: true).isEmpty)
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
