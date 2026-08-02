@preconcurrency import AppKit
import Combine
import Foundation

enum SecureStorageState: Equatable, Sendable {
    case checking
    case ready
    case needsApproval
    case unavailable(String)

    var displayName: String {
        switch self {
        case .checking: "Checking secure storage…"
        case .ready: "Secure storage is ready"
        case .needsApproval: "Keychain approval is required"
        case .unavailable(let message): message
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var selectedSection: MainSection = .journal
    @Published private(set) var events: [ActivityEvent] = []
    @Published private(set) var commitments: [Commitment] = []
    @Published private(set) var assistantHistory: [AssistantAnswer] = []
    @Published private(set) var captureHealth: CaptureHealth = .paused
    @Published private(set) var pendingCount = 0
    @Published private(set) var latestInsight: ActivityEvent?
    @Published private(set) var storageError: String?
    @Published var selectedEventID: UUID?
    @Published var isAsking = false
    @Published private(set) var exportMessage: String?
    @Published private(set) var isEnrollingVoice = false
    @Published private(set) var voiceEnrollmentMessage: String?
    @Published private(set) var secureStorageState: SecureStorageState = .checking

    let settingsStore = SettingsStore.shared
    private var repository: EncryptedSQLiteStore?
    private var mediaStore: EncryptedMediaStore?
    private var searchService: LocalSearchService?
    private let ai: any AIProviding
    private let screenCapture = ScreenCaptureService()
    private let audioCapture = AudioCaptureService()
    private let systemAudioCapture = SystemAudioCaptureService()
    private let ocr = VisionOCRService()
    private let notifications = NotificationService()
    private var maintenanceTask: Task<Void, Never>?
    private var lastScreenJPEG: Data?
    private var lastScreenContext: ActiveContext?

    init(ai: any AIProviding = OpenAIClient()) {
        self.ai = ai
        self.repository = nil
        self.mediaStore = nil
        self.searchService = nil
        self.storageError = nil

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in AppState.shared.pause() }
        }

        Task { [weak self] in
            await self?.bootstrap()
        }
    }

    deinit {
        maintenanceTask?.cancel()
        audioCapture.stop()
    }

    func bootstrap() async {
        if DistributionEnvironment.requiresExplicitKeychainUnlock {
            // Ad hoc builds have no stable designated requirement. macOS can therefore
            // challenge every rebuilt binary for each legacy Keychain item. Never let a
            // development build create those dialogs without an explicit user action.
            secureStorageState = .needsApproval
            storageError = "This development build needs one explicit Keychain unlock. No password dialog will open automatically."
            settingsStore.setAPIKeyState(.needsApproval)
            captureHealth = .permissionNeeded("Keychain access")
        } else {
            await initializeSecureStorage(interaction: .nonInteractive)
        }
        await refresh()
        await cleanup()
        await screenCapture.start(
            settingsProvider: { @Sendable in
                await MainActor.run { SettingsStore.shared.settings }
            },
            handler: { @Sendable frame in
                await AppState.shared.processScreenFrame(frame)
            }
        )
        configureAudio()
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                await self.maintenanceTick()
            }
        }
    }

    private func initializeSecureStorage(interaction: KeychainInteraction) async {
        secureStorageState = .checking
        do {
            let stores = try await Task.detached(priority: .userInitiated) {
                // These reads are intentionally sequential. macOS must never receive
                // multiple Keychain authorization requests from Iriz at once.
                let databaseKey = try SecurityBootstrap.keyData(
                    account: KeychainAccounts.databaseKey,
                    interaction: interaction
                )
                let mediaKey = try SecurityBootstrap.keyData(
                    account: KeychainAccounts.mediaKey,
                    interaction: interaction
                )
                let repository = try EncryptedSQLiteStore(keyData: databaseKey)
                let mediaStore = try EncryptedMediaStore(keyData: mediaKey)
                return (repository, mediaStore)
            }.value
            repository = stores.0
            mediaStore = stores.1
            searchService = LocalSearchService(repository: stores.0)
            secureStorageState = .ready
            DistributionEnvironment.markStableKeychainReady()
            storageError = nil
        } catch {
            repository = nil
            mediaStore = nil
            searchService = nil
            if let keychainError = error as? KeychainStoreError, keychainError.requiresUserApproval {
                secureStorageState = .needsApproval
                storageError = "Iriz needs one explicit Keychain approval before it can open your encrypted journal."
                captureHealth = .permissionNeeded("Keychain access")
            } else {
                secureStorageState = .unavailable(error.localizedDescription)
                storageError = error.localizedDescription
                captureHealth = .error(error.localizedDescription)
            }
            settingsStore.setAPIKeyState(.needsApproval)
            return
        }

        do {
            let loadVoiceReference = settingsStore.settings.voiceEnrollmentEnabled
            let credentials = try await Task.detached(priority: .utility) {
                let apiKey = try KeychainStore.shared.readString(
                    account: KeychainAccounts.openAIAPIKey,
                    interaction: interaction
                )
                let voiceReference = loadVoiceReference
                    ? try KeychainStore.shared.readData(
                        account: KeychainAccounts.voiceReference,
                        interaction: interaction
                    )
                    : nil
                return (apiKey, voiceReference)
            }.value
            settingsStore.installKeychainCache(apiKey: credentials.0, voiceReference: credentials.1)
        } catch {
            if let keychainError = error as? KeychainStoreError, keychainError.requiresUserApproval {
                settingsStore.setAPIKeyState(.needsApproval)
            } else {
                settingsStore.setAPIKeyState(.invalid(error.localizedDescription))
            }
        }
    }

    func unlockSecureStorage() async {
        await initializeSecureStorage(interaction: .userInitiated)
        guard secureStorageState == .ready else { return }
        await refresh()
        await cleanup()
        configureAudio()
        await retryPending()
    }

    func refresh() async {
        guard let repository else { return }
        do {
            async let eventValues = repository.events(limit: 500, importantOnly: false)
            async let commitmentValues = repository.commitments(includingClosed: false)
            async let pendingValues = repository.pendingObservations(limit: 500)
            events = try await eventValues
            commitments = try await commitmentValues
            pendingCount = try await pendingValues.count
            latestInsight = events.first(where: { $0.importance >= .important })
        } catch {
            storageError = error.localizedDescription
        }
    }

    func setPaused(_ paused: Bool) {
        settingsStore.settings.isPaused = paused
        if paused {
            captureHealth = .paused
            audioCapture.stop()
        } else {
            guard secureStorageState == .ready else {
                captureHealth = .permissionNeeded("Keychain access")
                return
            }
            captureHealth = settingsStore.settings.isAudioActiveNow ? .listening : .observing
            configureAudio()
            Task { await retryPending() }
        }
    }

    func pause() { setPaused(true) }
    func resume() { setPaused(false) }

    var observationMode: ObservationMode {
        ObservationMode.current(for: settingsStore.settings)
    }

    var observationStatusText: String {
        switch observationMode {
        case .observe: "Observing"
        case .listen: "Listening"
        case .observeAndListen: "Observing + listening"
        case .schedule:
            settingsStore.settings.isAudioActiveNow ? "Observing + listening" : "Observing · audio scheduled"
        case .paused: "Paused"
        }
    }

    func setObservationMode(_ mode: ObservationMode) {
        switch mode {
        case .observe:
            settingsStore.settings.screenCaptureEnabled = true
            settingsStore.settings.audioMode = .off
            setPaused(false)
        case .listen:
            settingsStore.settings.screenCaptureEnabled = false
            settingsStore.settings.audioMode = .alwaysOn
            setPaused(false)
        case .observeAndListen:
            settingsStore.settings.screenCaptureEnabled = true
            settingsStore.settings.audioMode = .alwaysOn
            setPaused(false)
        case .schedule:
            settingsStore.settings.screenCaptureEnabled = true
            settingsStore.settings.audioMode = .schedule
            setPaused(false)
        case .paused:
            setPaused(true)
        }
    }

    func configureAudio() {
        guard secureStorageState == .ready else {
            audioCapture.stop()
            Task { await systemAudioCapture.stop() }
            captureHealth = .permissionNeeded("Keychain access")
            return
        }
        guard settingsStore.settings.isAudioActiveNow else {
            audioCapture.stop()
            Task { await systemAudioCapture.stop() }
            if !settingsStore.settings.isPaused { captureHealth = .observing }
            return
        }
        guard PermissionService.microphoneState() == .granted else {
            captureHealth = .permissionNeeded("Microphone")
            return
        }
        do {
            try audioCapture.start { @Sendable wavData, duration in
                await AppState.shared.processAudio(wavData, voicedDuration: duration)
            }
            captureHealth = .listening
            if settingsStore.settings.meetingDetectionEnabled, lastScreenContext?.isMeeting == true {
                Task {
                    try? await systemAudioCapture.start { @Sendable wavData, duration in
                        await AppState.shared.processSystemAudio(wavData, voicedDuration: duration)
                    }
                }
            } else {
                Task { await systemAudioCapture.stop() }
            }
        } catch {
            captureHealth = .error(error.localizedDescription)
        }
    }

    func processScreenFrame(_ frame: CapturedScreenFrame) async {
        guard !settingsStore.settings.isPaused, let repository, let mediaStore else { return }
        captureHealth = frame.context.isMeeting ? .meeting : .processing
        lastScreenJPEG = frame.jpegData
        lastScreenContext = frame.context
        do {
            async let recognized = ocr.recognizeText(in: frame.image)
            let expiresAt = frame.capturedAt.addingTimeInterval(TimeInterval(settingsStore.settings.mediaRetentionHours * 3_600))
            let mediaID = try await mediaStore.store(frame.jpegData, fileExtension: "jpg", expiresAt: expiresAt)
            let text = ExclusionPolicy.redactSensitiveText(try await recognized)
            let observation = Observation(
                source: .screen,
                capturedAt: frame.capturedAt,
                expiresAt: expiresAt,
                applicationName: frame.context.applicationName,
                bundleIdentifier: frame.context.bundleIdentifier,
                windowTitle: frame.context.windowTitle,
                url: frame.context.url,
                text: text,
                mediaIdentifier: mediaID,
                contentFingerprint: frame.signature.digest,
                isMeeting: frame.context.isMeeting
            )
            try await repository.saveObservation(observation)
            pendingCount += 1
            await analyze(observation: observation, mediaData: frame.jpegData)
        } catch {
            captureHealth = .error(error.localizedDescription)
        }
        if !settingsStore.settings.isPaused {
            captureHealth = settingsStore.settings.isAudioActiveNow ? .listening : .observing
        }
    }

    func processAudio(_ wavData: Data, voicedDuration: TimeInterval) async {
        guard voicedDuration > 0 else { return }
        if isEnrollingVoice {
            do {
                let reference = WAVEncoder.cappedForVoiceReference(wavData)
                try settingsStore.saveVoiceReference(reference)
                isEnrollingVoice = false
                voiceEnrollmentMessage = "Voice sample saved securely as You."
                if !settingsStore.settings.isAudioActiveNow { audioCapture.stop() }
            } catch {
                isEnrollingVoice = false
                voiceEnrollmentMessage = error.localizedDescription
            }
            return
        }
        guard let repository, let mediaStore else { return }
        let now = Date()
        let expiresAt = now.addingTimeInterval(TimeInterval(settingsStore.settings.mediaRetentionHours * 3_600))
        do {
            let mediaID = try await mediaStore.store(wavData, fileExtension: "wav", expiresAt: expiresAt)
            var observation = Observation(
                source: lastScreenContext?.isMeeting == true ? .meetingMicrophone : .ambientAudio,
                capturedAt: now,
                expiresAt: expiresAt,
                applicationName: lastScreenContext?.applicationName,
                bundleIdentifier: lastScreenContext?.bundleIdentifier,
                windowTitle: lastScreenContext?.windowTitle,
                url: lastScreenContext?.url,
                mediaIdentifier: mediaID,
                isMeeting: lastScreenContext?.isMeeting ?? false
            )
            try await repository.saveObservation(observation)
            pendingCount += 1
            guard let key = try settingsStore.apiKey() else { return }
            captureHealth = .processing
            let transcript = try await ai.transcribe(
                wavData: wavData,
                diarize: observation.isMeeting,
                languageTag: settingsStore.settings.outputLanguageTag,
                knownSpeakerReference: observation.isMeeting ? try settingsStore.voiceReference() : nil,
                apiKey: key
            )
            observation.text = ExclusionPolicy.redactSensitiveText(transcript)
            try await repository.saveObservation(observation)
            await analyze(observation: observation, mediaData: nil)
        } catch {
            captureHealth = .error(error.localizedDescription)
        }
    }

    func processSystemAudio(_ wavData: Data, voicedDuration: TimeInterval) async {
        guard voicedDuration > 0, let repository, let mediaStore else { return }
        let now = Date()
        let expiresAt = now.addingTimeInterval(TimeInterval(settingsStore.settings.mediaRetentionHours * 3_600))
        do {
            let mediaID = try await mediaStore.store(wavData, fileExtension: "wav", expiresAt: expiresAt)
            var observation = Observation(
                source: .meetingSystemAudio,
                capturedAt: now,
                expiresAt: expiresAt,
                applicationName: lastScreenContext?.applicationName,
                bundleIdentifier: lastScreenContext?.bundleIdentifier,
                windowTitle: lastScreenContext?.windowTitle,
                url: lastScreenContext?.url,
                mediaIdentifier: mediaID,
                isMeeting: true
            )
            try await repository.saveObservation(observation)
            pendingCount += 1
            guard let key = try settingsStore.apiKey() else { return }
            observation.text = ExclusionPolicy.redactSensitiveText(try await ai.transcribe(
                wavData: wavData,
                diarize: true,
                languageTag: settingsStore.settings.outputLanguageTag,
                knownSpeakerReference: try settingsStore.voiceReference(),
                apiKey: key
            ))
            try await repository.saveObservation(observation)
            await analyze(observation: observation, mediaData: nil)
        } catch {
            captureHealth = .error(error.localizedDescription)
        }
    }

    func retryPending() async {
        guard let repository, let mediaStore, (try? settingsStore.apiKey()) != nil else { return }
        do {
            let pending = try await repository.pendingObservations(limit: 25)
            pendingCount = pending.count
            for var observation in pending where observation.expiresAt > Date() {
                var media: Data?
                if let identifier = observation.mediaIdentifier {
                    media = try? await mediaStore.read(identifier: identifier)
                }
                if observation.source != .screen, observation.text.isEmpty, let media,
                   let key = try settingsStore.apiKey() {
                    observation.text = try await ai.transcribe(
                        wavData: media,
                        diarize: observation.isMeeting,
                        languageTag: settingsStore.settings.outputLanguageTag,
                        knownSpeakerReference: observation.isMeeting ? try settingsStore.voiceReference() : nil,
                        apiKey: key
                    )
                    try await repository.saveObservation(observation)
                    await analyze(observation: observation, mediaData: nil)
                } else {
                    await analyze(observation: observation, mediaData: media)
                }
            }
        } catch {
            captureHealth = .error(error.localizedDescription)
        }
    }

    func addNote(_ text: String) async {
        guard let repository else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let now = Date()
        let event = ActivityEvent(
            startedAt: now,
            endedAt: now,
            kind: .note,
            status: .completed,
            importance: .important,
            title: String(trimmed.prefix(80)),
            summary: trimmed,
            languageTag: settingsStore.settings.outputLanguageTag == "auto" ? "en-US" : settingsStore.settings.outputLanguageTag,
            confidence: 1
        )
        do {
            try await repository.saveEvent(event)
            await refresh()
        } catch {
            storageError = error.localizedDescription
        }
    }

    func beginVoiceEnrollment() async {
        guard await PermissionService.requestMicrophone() else {
            voiceEnrollmentMessage = "Microphone permission is required."
            return
        }
        isEnrollingVoice = true
        voiceEnrollmentMessage = "Speak naturally for 2–10 seconds, then pause."
        do {
            try audioCapture.start { @Sendable wavData, duration in
                await AppState.shared.processAudio(wavData, voicedDuration: duration)
            }
        } catch {
            isEnrollingVoice = false
            voiceEnrollmentMessage = error.localizedDescription
        }
    }

    func removeVoiceEnrollment() {
        do {
            try settingsStore.removeVoiceReference()
            voiceEnrollmentMessage = "Voice sample removed."
        } catch {
            voiceEnrollmentMessage = error.localizedDescription
        }
    }

    func markMoment() async {
        let context = lastScreenContext
        let text = ["Marked moment", context?.windowTitle, context?.url?.absoluteString].compactMap { $0 }.joined(separator: " — ")
        await addNote(text)
    }

    func ask(_ question: String) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let searchService else { return }
        isAsking = true
        defer { isAsking = false }
        do {
            let candidates = try await searchService.candidates(for: trimmed)
            let answer: AssistantAnswer
            if let key = try settingsStore.apiKey() {
                answer = try await ai.answer(
                    question: trimmed,
                    candidates: candidates,
                    outputLanguage: settingsStore.outputLanguageDescription(),
                    apiKey: key
                )
            } else if let first = candidates.first {
                let urlText = first.urls.first.map { " \($0.absoluteString)" } ?? ""
                answer = AssistantAnswer(
                    question: trimmed,
                    text: "I found a likely match: \(first.title). \(first.summary)\(urlText)",
                    citations: [AssistantCitation(eventID: first.id, title: first.title, timestamp: first.startedAt, url: first.urls.first)]
                )
            } else {
                answer = AssistantAnswer(question: trimmed, text: "No matching evidence was found.", citations: [])
            }
            assistantHistory.append(answer)
        } catch {
            assistantHistory.append(AssistantAnswer(question: trimmed, text: error.localizedDescription, citations: []))
        }
    }

    func updateCommitment(_ value: Commitment, state: CommitmentState) async {
        guard let repository else { return }
        var updated = value
        updated.state = state
        updated.updatedAt = Date()
        try? await repository.saveCommitment(updated)
        await refresh()
    }

    func snoozeCommitment(_ value: Commitment, days: Int) async {
        guard let repository else { return }
        var updated = value
        updated.state = .later
        updated.suggestedReviewAt = Calendar.current.date(byAdding: .day, value: days, to: Date())
        updated.updatedAt = Date()
        try? await repository.saveCommitment(updated)
        await refresh()
    }

    func openEvent(_ id: UUID) {
        selectedEventID = id
        selectedSection = .journal
        openMainWindow()
    }

    func openMainWindow(section: MainSection? = nil) {
        if let section { selectedSection = section }
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { !($0 is NSPanel) }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            NotificationCenter.default.post(name: .irizOpenMainWindow, object: nil)
        }
    }

    func testAPIKey(_ candidate: String) async {
        settingsStore.setAPIKeyState(.testing)
        do {
            try await ai.validateAPIKey(candidate)
            try settingsStore.saveAPIKey(candidate)
            settingsStore.setAPIKeyState(.valid)
            await retryPending()
        } catch {
            settingsStore.setAPIKeyState(.invalid(error.localizedDescription))
        }
    }

    func cleanup() async {
        guard let repository, let mediaStore else { return }
        do {
            try await repository.purgeExpired(now: Date(), retention: settingsStore.settings.structuredRetention)
            try await mediaStore.purgeExpired(now: Date())
            try await mediaStore.removeTemporaryFiles()
            await refresh()
        } catch {
            storageError = error.localizedDescription
        }
    }

    func exportJournal(format: ExportFormat) async {
        guard let repository else { return }
        do {
            let eventValues = try await repository.events(limit: 100_000, importantOnly: false)
            let commitmentValues = try await repository.commitments(includingClosed: true)
            let data = try ExportService.render(events: eventValues, commitments: commitmentValues, format: format)
            if let url = try ExportService.save(data, format: format) {
                exportMessage = "Exported to \(url.lastPathComponent)."
            }
        } catch {
            exportMessage = error.localizedDescription
        }
    }

    private func analyze(observation: Observation, mediaData: Data?) async {
        guard let repository else { return }
        do {
            guard let key = try settingsStore.apiKey() else { return }
            let interpretation = try await ai.interpret(
                observation: observation,
                imageData: observation.source == .screen ? mediaData : nil,
                outputLanguage: settingsStore.outputLanguageDescription(),
                apiKey: key
            )
            if interpretation.shouldCreateEvent, let event = interpretation.event {
                let consolidated = await consolidate(event)
                try await repository.saveEvent(consolidated)
                let openCommitments = try await repository.commitments(includingClosed: false)
                for existing in openCommitments {
                    if let linked = CommitmentLinker.linking(existing, to: consolidated) {
                        try await repository.saveCommitment(linked)
                    }
                }
                for draft in interpretation.commitments {
                    let state: CommitmentState = draft.confidence < 0.7 ? .maybe : draft.state
                    let commitment = Commitment(
                        eventID: consolidated.id,
                        owner: draft.owner,
                        action: draft.action,
                        rationale: draft.rationale,
                        explicitDueAt: draft.explicitDueAt,
                        suggestedReviewAt: draft.suggestedReviewAt,
                        confidence: draft.confidence,
                        state: state
                    )
                    try await repository.saveCommitment(commitment)
                }
                if consolidated.importance >= .important { latestInsight = consolidated }
            }
            try await repository.markObservationProcessed(id: observation.id, at: Date())
            pendingCount = max(0, pendingCount - 1)
            await refresh()
        } catch {
            // The encrypted observation remains pending and can be retried until its 24-hour expiry.
            captureHealth = .error(error.localizedDescription)
        }
    }

    private func consolidate(_ proposed: ActivityEvent) async -> ActivityEvent {
        guard let repository,
              let recent = try? await repository.events(limit: 25, importantOnly: false) else { return proposed }
        let host = proposed.urls.first?.host()
        let consolidationWindow: TimeInterval = proposed.kind == .meeting ? 3 * 60 * 60 : 15 * 60
        guard var match = recent.first(where: {
            $0.kind == proposed.kind &&
            proposed.startedAt.timeIntervalSince($0.endedAt) < consolidationWindow &&
            (host == nil || $0.urls.first?.host() == host)
        }) else { return proposed }
        match.endedAt = max(match.endedAt, proposed.endedAt)
        if proposed.status == .completed || match.status != .completed { match.status = proposed.status }
        if proposed.confidence >= match.confidence {
            match.title = proposed.title
            match.summary = proposed.summary
            match.details = proposed.details
            match.confidence = proposed.confidence
        }
        match.importance = max(match.importance, proposed.importance)
        match.entities = Array(Set(match.entities + proposed.entities)).sorted()
        match.urls = Array(Set(match.urls + proposed.urls))
        match.sourceApplications = Array(Set(match.sourceApplications + proposed.sourceApplications)).sorted()
        match.evidence.append(contentsOf: proposed.evidence)
        match.evidence = Array(match.evidence.suffix(3))
        match.updatedAt = Date()
        return match
    }

    private func maintenanceTick() async {
        configureAudio()
        await cleanup()
        if !settingsStore.settings.isPaused { await retryPending() }
        if settingsStore.settings.dailyDigestEnabled {
            await notifications.configureDailyDigest(hour: settingsStore.settings.dailyDigestHour, enabled: true)
        }
    }
}
