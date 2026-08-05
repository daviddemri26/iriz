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

    @Published var selectedSection: MainSection = .initial
    @Published var selectedSettingsCategory: SettingsCategory = .capture
    @Published private(set) var events: [ActivityEvent] = []
    @Published private(set) var commitments: [Commitment] = []
    @Published private(set) var resolvedCommitments: [Commitment] = []
    @Published private(set) var followUpSubjects: [FollowUpSubject] = []
    @Published private(set) var followUpTypes: [FollowUpType] = []
    @Published private(set) var assistantConversations: [AssistantConversation] = []
    @Published private(set) var selectedAssistantConversationID: UUID?
    @Published private(set) var pendingAssistantTurn: PendingAssistantTurn?
    @Published private(set) var captureHealth: CaptureHealth = .paused
    @Published private(set) var indicatorSnapshot = IndicatorActivitySnapshot()
    @Published private(set) var pendingCount = 0
    @Published private(set) var latestInsight: ActivityEvent?
    @Published private(set) var storageError: String?
    @Published private(set) var presentedEvent: ActivityEvent?
    @Published var isAsking = false
    @Published private(set) var exportMessage: String?
    @Published private(set) var isEnrollingVoice = false
    @Published private(set) var voiceEnrollmentMessage: String?
    @Published private(set) var secureStorageState: SecureStorageState = .checking
    @Published private(set) var followUpOperationMessage: String?
    @Published private(set) var pendingFollowUpMergeConfirmation: PendingFollowUpMergeConfirmation?

    let settingsStore = SettingsStore.shared
    private var repository: EncryptedSQLiteStore?
    private var mediaStore: EncryptedMediaStore?
    private var searchService: LocalSearchService?
    let indicatorActivities: IndicatorActivityStore
    private let ai: any AIProviding
    private let screenCapture = ScreenCaptureService()
    private let audioCapture = AudioCaptureService()
    private let systemAudioCapture = SystemAudioCaptureService()
    private let ocr = VisionOCRService()
    private let notifications = NotificationService()
    private let followUpExporter = FollowUpExportService()
    private var maintenanceTask: Task<Void, Never>?
    private var lastScreenJPEG: Data?
    private var lastScreenContext: ActiveContext?
    private var screenCaptureFailureMessage: String?
    private var audioCaptureFailureMessage: String?
    private var isComposingNewAssistantConversation = false
    private var indicatorSnapshotCancellable: AnyCancellable?
    private var apiKeyStateCancellable: AnyCancellable?

    init(
        ai: (any AIProviding)? = nil,
        indicatorActivities: IndicatorActivityStore? = nil
    ) {
        let activityStore = indicatorActivities ?? IndicatorActivityStore()
        self.indicatorActivities = activityStore
        self.ai = ai ?? OpenAIClient(indicatorActivities: activityStore)
        self.repository = nil
        self.mediaStore = nil
        self.searchService = nil
        self.storageError = nil
        self.indicatorSnapshot = activityStore.snapshot
        self.indicatorSnapshotCancellable = activityStore.$snapshot.sink { [weak self] snapshot in
            self?.indicatorSnapshot = snapshot
        }
        self.apiKeyStateCancellable = settingsStore.$apiKeyState
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.captureHealth = self.configuredCaptureHealth
            }

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
            visibilityHandler: { @Sendable visibility in
                await AppState.shared.updateScreenVisibility(visibility)
            },
            failureHandler: { @Sendable message in
                await AppState.shared.updateScreenCaptureFailure(message)
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
            storageError = nil
        } catch {
            repository = nil
            mediaStore = nil
            searchService = nil
            if let keychainError = error as? KeychainStoreError, keychainError.requiresUserApproval {
                secureStorageState = .needsApproval
                storageError = "iriz needs one explicit Keychain approval before it can open your encrypted memory."
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
                captureHealth = .permissionNeeded("Keychain access")
            } else {
                settingsStore.setAPIKeyState(.invalid(error.localizedDescription))
                captureHealth = .error("Keychain access needs attention.")
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
            async let commitmentValues = repository.commitments(includingClosed: true)
            async let pendingValues = repository.pendingObservations(limit: 500)
            async let conversationValues = repository.assistantConversations(limit: 100)
            async let subjectValues = repository.followUpSubjects()
            async let typeValues = repository.followUpTypes()
            events = try await eventValues
            var allCommitments = try await commitmentValues
            let now = Date()
            for index in allCommitments.indices where allCommitments[index].lifecycle == .snoozed {
                guard let returnAt = allCommitments[index].snoozedUntil, returnAt <= now else { continue }
                allCommitments[index].setLifecycle(.active, actor: .system, now: now)
                allCommitments[index].surfacedAt = now
                try await repository.saveCommitment(allCommitments[index])
            }
            commitments = allCommitments
                .filter { $0.lifecycle != .completed }
                .sorted { $0.surfacedAt > $1.surfacedAt }
            resolvedCommitments = allCommitments
                .filter { $0.lifecycle == .completed }
                .sorted { ($0.completedAt ?? $0.updatedAt) > ($1.completedAt ?? $1.updatedAt) }
            var typesByID = Dictionary(uniqueKeysWithValues: (try await typeValues).map { ($0.id, $0) })
            for defaultType in FollowUpType.defaults where typesByID[defaultType.id] == nil {
                try await repository.saveFollowUpType(defaultType)
                typesByID[defaultType.id] = defaultType
            }
            followUpTypes = typesByID.values.sorted {
                if $0.isBuiltIn != $1.isBuiltIn { return $0.isBuiltIn }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            followUpSubjects = try await subjectValues
            try await synchronizeFollowUpSubjects(for: allCommitments, repository: repository)
            pendingCount = try await pendingValues.count
            assistantConversations = try await conversationValues
            if !isComposingNewAssistantConversation,
               selectedAssistantConversationID == nil || !assistantConversations.contains(where: { $0.id == selectedAssistantConversationID }) {
                selectedAssistantConversationID = assistantConversations.first?.id
            }
            latestInsight = events.first(where: { $0.importance >= .important })
        } catch {
            storageError = error.localizedDescription
        }
    }

    private func synchronizeFollowUpSubjects(
        for values: [Commitment],
        repository: EncryptedSQLiteStore
    ) async throws {
        var byID = Dictionary(followUpSubjects.map { ($0.id, $0) }) { lhs, rhs in
            lhs.updatedAt >= rhs.updatedAt ? lhs : rhs
        }
        for (identifier, storedSubject) in byID {
            guard storedSubject.typeID == nil || !followUpTypes.contains(where: { $0.id == storedSubject.typeID }) else { continue }
            var subject = storedSubject
            subject.typeID = FollowUpType.defaultID(for: subject.area)
            subject.updatedAt = Date()
            try await repository.saveFollowUpSubject(subject)
            byID[identifier] = subject
        }
        let eventsByID = Dictionary(events.map { ($0.id, $0) }) { lhs, rhs in
            lhs.updatedAt >= rhs.updatedAt ? lhs : rhs
        }
        var synchronizedValues = values

        for index in synchronizedValues.indices {
            var commitment = synchronizedValues[index]
            let canRefineSubject = !commitment.manuallyEditedFields.contains(.subject)
                && FollowUpContextGrouper.isGenericSubjectName(commitment.contextLabel)

            if canRefineSubject {
                let evidenceEvent = eventsByID[commitment.eventID]
                    ?? commitment.linkedEventIDs.reversed().compactMap { eventsByID[$0] }.first
                let concreteName = FollowUpContextGrouper.specificSubjectLabel(
                    suggested: commitment.contextLabel,
                    action: commitment.action,
                    context: [commitment.summary, commitment.details, commitment.rationale]
                        .filter { !$0.isEmpty }
                        .joined(separator: " "),
                    event: evidenceEvent,
                    area: commitment.area
                )
                let resolution = FollowUpContextGrouper.resolveOrCreateSubject(
                    named: concreteName,
                    area: commitment.area,
                    in: Array(byID.values)
                )
                if resolution.wasCreated {
                    try await repository.saveFollowUpSubject(resolution.subject)
                    byID[resolution.subject.id] = resolution.subject
                }
                if commitment.subjectID != resolution.subject.id
                    || commitment.contextLabel != resolution.subject.name {
                    let previousName = commitment.contextLabel ?? commitment.area.displayName
                    commitment.subjectID = resolution.subject.id
                    commitment.contextLabel = resolution.subject.name
                    commitment.area = resolution.subject.area
                    commitment.updatedAt = Date()
                    commitment.history.append(FollowUpHistoryEntry(
                        kind: .edited,
                        actor: .iriz,
                        summary: "Subject refined from \(previousName) to \(resolution.subject.name)"
                    ))
                    try await repository.saveCommitment(commitment)
                    synchronizedValues[index] = commitment
                }
                continue
            }

            let name = FollowUpContextGrouper.canonicalLabel(commitment.contextLabel) ?? "Uncategorized"
            let identifier = commitment.subjectID ?? FollowUpSubject.identifier(for: name)
            guard byID[identifier] == nil else { continue }
            let subject = FollowUpSubject(
                id: identifier,
                name: name,
                area: commitment.area == .uncategorized ? .inferred(from: name) : commitment.area,
                typeID: FollowUpType.defaultID(for: commitment.area == .uncategorized ? .inferred(from: name) : commitment.area)
            )
            try await repository.saveFollowUpSubject(subject)
            byID[identifier] = subject
        }

        commitments = synchronizedValues
            .filter { $0.lifecycle != .completed }
            .sorted { $0.surfacedAt > $1.surfacedAt }
        resolvedCommitments = synchronizedValues
            .filter { $0.lifecycle == .completed }
            .sorted { ($0.completedAt ?? $0.updatedAt) > ($1.completedAt ?? $1.updatedAt) }
        let usedSubjectIDs = Set(synchronizedValues.compactMap(\.subjectID))
        followUpSubjects = byID.values
            .filter { !FollowUpContextGrouper.isGenericSubjectName($0.name) || usedSubjectIDs.contains($0.id) }
            .sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func setPaused(_ paused: Bool) {
        if !paused,
           !settingsStore.settings.screenCaptureEnabled,
           settingsStore.settings.audioMode == .off {
            settingsStore.settings.screenCaptureEnabled = true
        }
        settingsStore.settings.isPaused = paused
        if paused {
            audioCapture.stop()
            Task { await systemAudioCapture.stop() }
        } else {
            guard secureStorageState == .ready else {
                captureHealth = .permissionNeeded("Keychain access")
                return
            }
            configureAudio()
            Task { await retryPending() }
        }
        captureHealth = configuredCaptureHealth
    }

    func pause() { setPaused(true) }
    func resume() { setPaused(false) }

    var observationMode: ObservationMode {
        ObservationMode.current(for: settingsStore.settings)
    }

    var isObserveEnabled: Bool {
        settingsStore.settings.screenCaptureEnabled
    }

    var isListenEnabled: Bool {
        settingsStore.settings.isListenEnabled
    }

    var observationStatusText: String {
        let configured = settingsStore.settings
        if configured.isPaused { return "Paused" }
        if configured.captureTiming == .schedule, !configured.isCaptureWindowActive(at: Date()) {
            return "Waiting — not capturing until the scheduled hours"
        }
        if configured.isScreenCaptureActiveNow, configured.isAudioActiveNow { return "Observing + listening" }
        if configured.isScreenCaptureActiveNow { return "Observing" }
        if configured.isAudioActiveNow { return "Listening" }
        return "Paused"
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
            settingsStore.settings.audioMode = .alwaysOn
            settingsStore.settings.captureTiming = .schedule
            setPaused(false)
        case .paused:
            setPaused(true)
        }
    }

    func setObserveEnabled(_ enabled: Bool) {
        settingsStore.settings.setObserveEnabled(enabled)
        if settingsStore.settings.isPaused { captureHealth = configuredCaptureHealth }
        guard !settingsStore.settings.isPaused else { return }
        configureAudio()
    }

    func setListenEnabled(_ enabled: Bool) {
        settingsStore.settings.setListenEnabled(enabled)
        if settingsStore.settings.isPaused { captureHealth = configuredCaptureHealth }
        configureAudio()
    }

    func setListeningBehavior(_ mode: AudioMode) {
        settingsStore.settings.setListeningBehavior(mode)
        configureAudio()
    }

    func setCaptureTiming(_ timing: CaptureTiming) {
        settingsStore.settings.setCaptureTiming(timing)
        configureAudio()
    }

    func configureAudio() {
        guard secureStorageState == .ready else {
            audioCapture.stop()
            Task { await systemAudioCapture.stop() }
            captureHealth = configuredCaptureHealth
            return
        }
        guard settingsStore.settings.isAudioActiveNow else {
            audioCapture.stop()
            Task { await systemAudioCapture.stop() }
            audioCaptureFailureMessage = nil
            captureHealth = configuredCaptureHealth
            return
        }
        guard PermissionService.microphoneState() == .granted else {
            audioCapture.stop()
            Task { await systemAudioCapture.stop() }
            audioCaptureFailureMessage = nil
            captureHealth = configuredCaptureHealth
            return
        }
        do {
            try audioCapture.start { @Sendable wavData, duration in
                await AppState.shared.processAudio(wavData, voicedDuration: duration)
            }
            audioCaptureFailureMessage = nil
            captureHealth = configuredCaptureHealth
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
            audioCaptureFailureMessage = "Microphone observation is unavailable."
            captureHealth = configuredCaptureHealth
        }
    }

    func updateScreenVisibility(_ visibility: ScreenContextVisibility) {
        indicatorActivities.setScreenVisibility(visibility)
        if visibility != .available {
            // Never let a previously available app/window become fallback metadata
            // after the active context turns private or unavailable.
            lastScreenContext = nil
            lastScreenJPEG = nil
            Task { await systemAudioCapture.stop() }
        }
        captureHealth = configuredCaptureHealth
    }

    func updateScreenCaptureFailure(_ message: String?) {
        guard screenCaptureFailureMessage != message else { return }
        screenCaptureFailureMessage = message
        captureHealth = configuredCaptureHealth
    }

    func processScreenFrame(_ frame: CapturedScreenFrame) async {
        guard !settingsStore.settings.isPaused, let repository, let mediaStore else { return }
        let activityContext: IndicatorActivityContext = frame.context.isMeeting ? .meeting : .screen
        let activityToken = indicatorActivities.beginLocal(
            IndicatorLocalActivityDescriptor(context: activityContext, startedAt: frame.capturedAt)
        )
        defer { indicatorActivities.finishLocal(activityToken) }
        indicatorActivities.setScreenVisibility(.available)
        if !hasPersistentIndicatorIssue {
            captureHealth = frame.context.isMeeting ? .meeting : configuredCaptureHealth
        }
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
            handleProcessingError(error, context: activityContext)
        }
        if !settingsStore.settings.isPaused, !hasPersistentIndicatorIssue {
            captureHealth = configuredCaptureHealth
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
        let activityContext: IndicatorActivityContext = lastScreenContext?.isMeeting == true ? .meeting : .voice
        let activityToken = indicatorActivities.beginLocal(
            IndicatorLocalActivityDescriptor(context: activityContext)
        )
        defer { indicatorActivities.finishLocal(activityToken) }
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
            handleProcessingError(error, context: activityContext)
        }
        if !settingsStore.settings.isPaused, !hasPersistentIndicatorIssue {
            captureHealth = configuredCaptureHealth
        }
    }

    func processSystemAudio(_ wavData: Data, voicedDuration: TimeInterval) async {
        guard voicedDuration > 0, let repository, let mediaStore else { return }
        let activityToken = indicatorActivities.beginLocal(
            IndicatorLocalActivityDescriptor(context: .meeting)
        )
        defer { indicatorActivities.finishLocal(activityToken) }
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
            handleProcessingError(error, context: .meeting)
        }
        if !settingsStore.settings.isPaused, !hasPersistentIndicatorIssue {
            captureHealth = configuredCaptureHealth
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
            handleProcessingError(error, context: .followUp)
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

    var selectedAssistantConversation: AssistantConversation? {
        guard let selectedAssistantConversationID else { return nil }
        return assistantConversations.first(where: { $0.id == selectedAssistantConversationID })
    }

    var assistantHistory: [AssistantAnswer] {
        selectedAssistantConversation?.answers ?? []
    }

    var pinnedAssistantConversations: [AssistantConversation] {
        AssistantConversationPinning.pinned(from: assistantConversations)
    }

    func startNewAssistantConversation() {
        isComposingNewAssistantConversation = true
        selectedAssistantConversationID = nil
    }

    func selectAssistantConversation(_ id: UUID) {
        guard assistantConversations.contains(where: { $0.id == id }) else { return }
        isComposingNewAssistantConversation = false
        selectedAssistantConversationID = id
    }

    func setAssistantConversationPinned(_ id: UUID, isPinned: Bool) async {
        guard let index = assistantConversations.firstIndex(where: { $0.id == id }) else { return }
        let updated = AssistantConversationPinning.updating(
            assistantConversations[index],
            isPinned: isPinned
        )
        assistantConversations[index] = updated
        try? await repository?.saveAssistantConversation(updated)
    }

    func toggleAssistantConversationPinned(_ id: UUID) async {
        guard let conversation = assistantConversations.first(where: { $0.id == id }) else { return }
        await setAssistantConversationPinned(id, isPinned: conversation.pinnedAt == nil)
    }

    func deleteAssistantConversation(_ id: UUID) async {
        guard let repository, pendingAssistantTurn?.conversationID != id else { return }
        try? await repository.deleteAssistantConversation(id: id)
        assistantConversations.removeAll(where: { $0.id == id })
        if selectedAssistantConversationID == id {
            selectedAssistantConversationID = assistantConversations.first?.id
        }
        if assistantConversations.isEmpty {
            isComposingNewAssistantConversation = true
            selectedAssistantConversationID = nil
        }
    }

    func ask(_ question: String) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAsking, let searchService, let repository else { return }

        var conversation = selectedAssistantConversation ?? AssistantConversation(
            title: AssistantConversation.title(for: trimmed)
        )
        let conversationID = conversation.id
        if conversation.answers.isEmpty {
            conversation.title = AssistantConversation.title(for: trimmed)
        }
        conversation.updatedAt = Date()
        isComposingNewAssistantConversation = false
        selectedAssistantConversationID = conversationID
        upsertAssistantConversation(conversation)
        try? await repository.saveAssistantConversation(conversation)

        let previousAnswers = conversation.answers
        let retrievalQuery = (previousAnswers.suffix(2).map(\.question) + [trimmed]).joined(separator: " ")
        pendingAssistantTurn = PendingAssistantTurn(conversationID: conversationID, question: trimmed)
        isAsking = true
        defer {
            isAsking = false
            if pendingAssistantTurn?.conversationID == conversationID {
                pendingAssistantTurn = nil
            }
        }

        let answer: AssistantAnswer
        do {
            let candidates = try await searchService.candidates(for: retrievalQuery)
            if let key = try settingsStore.apiKey() {
                answer = try await ai.answer(
                    question: trimmed,
                    candidates: candidates,
                    conversationContext: Array(previousAnswers.suffix(4)),
                    outputLanguage: settingsStore.outputLanguagePrompt(),
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
        } catch {
            handleProcessingError(error, context: .assistant)
            answer = AssistantAnswer(question: trimmed, text: error.localizedDescription, citations: [])
        }

        conversation.answers.append(answer)
        conversation.updatedAt = Date()
        upsertAssistantConversation(conversation)
        try? await repository.saveAssistantConversation(conversation)
    }

    private func upsertAssistantConversation(_ conversation: AssistantConversation) {
        if let index = assistantConversations.firstIndex(where: { $0.id == conversation.id }) {
            assistantConversations[index] = conversation
        } else {
            assistantConversations.append(conversation)
        }
        assistantConversations.sort { $0.updatedAt > $1.updatedAt }
    }

    func updateCommitment(_ value: Commitment, state: CommitmentState) async {
        guard let repository else { return }
        var updated = value
        let lifecycle = FollowUpLifecycle.migrate(from: state, reviewAt: updated.dueAt)
        updated.setLifecycle(lifecycle, actor: .user)
        if lifecycle == .completed { updated.completionActor = .user }
        await persistFollowUpMutation(updated, repository: repository)
    }

    func setCommitmentPriority(_ value: Commitment, isPriority: Bool) async {
        await setFollowUpPriority(value, score: isPriority ? max(8, value.priorityScore) : min(7, value.priorityScore))
    }

    func snoozeCommitment(_ value: Commitment, days: Int) async {
        guard let date = Calendar.current.date(byAdding: .day, value: days, to: Date()) else { return }
        await snoozeFollowUp(value, until: date)
    }

    @discardableResult
    func createManualFollowUp(
        action: String,
        summary: String = "",
        details: String = "",
        subjectID: String? = nil,
        priority: Int = 5,
        dueAt: Date? = nil
    ) async -> UUID? {
        guard let repository else { return nil }
        let cleanAction = action.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanAction.isEmpty else {
            followUpOperationMessage = "Add a title before saving this Action."
            return nil
        }
        let now = Date()
        let subject = subjectID.flatMap { id in followUpSubjects.first(where: { $0.id == id }) }
        var authoritativeFields: Set<FollowUpEditableField> = [.action, .priority]
        if !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { authoritativeFields.insert(.summary) }
        if !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { authoritativeFields.insert(.details) }
        if subjectID != nil { authoritativeFields.insert(.subject) }
        if dueAt != nil { authoritativeFields.insert(.dueDate) }
        let event = ActivityEvent(
            startedAt: now,
            endedAt: now,
            kind: .task,
            status: .inProgress,
            importance: priority >= 8 ? .important : .normal,
            title: cleanAction,
            summary: summary,
            details: details,
            languageTag: settingsStore.settings.outputLanguageTag,
            confidence: 1
        )
        var value = Commitment(
            eventID: event.id,
            owner: "You",
            action: cleanAction,
            rationale: "Created manually.",
            explicitDueAt: dueAt,
            contextLabel: subject?.name ?? "Uncategorized",
            confidence: 1,
            state: .needsAttention,
            summary: summary,
            details: details,
            lifecycle: .active,
            subjectID: subject?.id ?? FollowUpSubject.identifier(for: "Uncategorized"),
            area: subject?.area ?? .uncategorized,
            origin: .manual,
            detailLevelAtCreation: settingsStore.settings.followUpDetailLevel,
            aiPriorityScore: priority,
            displayPriorityScore: priority,
            userPriorityScore: priority,
            priorityReason: "Set when created",
            surfacedAt: now,
            dueSource: dueAt == nil ? nil : .user,
            dueConfidence: dueAt == nil ? nil : 1,
            manuallyEditedFields: authoritativeFields,
            history: [FollowUpHistoryEntry(kind: .created, actor: .user, summary: "Created manually", occurredAt: now)]
        )
        value.isPriority = priority >= 8
        do {
            try await repository.saveEvent(event)
            try await repository.saveCommitment(value)
            followUpOperationMessage = nil
            await refresh()
            return value.id
        } catch {
            followUpOperationMessage = error.localizedDescription
            return nil
        }
    }

    func saveEditedFollowUp(_ value: Commitment, fields: Set<FollowUpEditableField>) async {
        guard let repository,
              var updated = (commitments + resolvedCommitments).first(where: { $0.id == value.id }) else { return }
        let now = Date()
        if fields.contains(.action) { updated.action = value.action.trimmingCharacters(in: .whitespacesAndNewlines) }
        if fields.contains(.summary) { updated.summary = value.summary }
        if fields.contains(.details) { updated.details = value.details }
        if fields.contains(.owner) { updated.owner = value.owner }
        if fields.contains(.dueDate) {
            updated.explicitDueAt = value.explicitDueAt
            updated.suggestedReviewAt = nil
            updated.dueSource = value.explicitDueAt == nil ? nil : .user
            updated.dueConfidence = value.explicitDueAt == nil ? nil : 1
        }
        updated.manuallyEditedFields.formUnion(fields)
        updated.updatedAt = now
        updated.history.append(FollowUpHistoryEntry(
            kind: .edited,
            actor: .user,
            summary: "Updated \(fields.map(\.rawValue).sorted().joined(separator: ", "))",
            occurredAt: now
        ))
        do {
            try await repository.saveCommitment(updated)
            followUpOperationMessage = nil
            await refresh()
        } catch {
            handleProcessingError(error, context: .followUp)
            followUpOperationMessage = error.localizedDescription
        }
    }

    func setFollowUpPriority(_ value: Commitment, score: Int) async {
        guard let repository,
              var updated = (commitments + resolvedCommitments).first(where: { $0.id == value.id }) else { return }
        let bounded = min(max(score, 0), 10)
        updated.userPriorityScore = bounded
        updated.isPriority = bounded >= 8
        updated.manuallyEditedFields.insert(.priority)
        updated.updatedAt = Date()
        updated.history.append(FollowUpHistoryEntry(
            kind: .prioritized,
            actor: .user,
            summary: "Priority changed to \(bounded)/10"
        ))
        do {
            if let subjectID = updated.subjectID,
               var subject = followUpSubjects.first(where: { $0.id == subjectID }) {
                subject.learn(aiScore: updated.aiPriorityScore, userScore: bounded)
                try await repository.saveFollowUpSubject(subject)
            }
            try await repository.saveCommitment(updated)
            followUpOperationMessage = nil
            await refresh()
        } catch {
            followUpOperationMessage = error.localizedDescription
        }
    }

    func assignFollowUp(_ value: Commitment, to subjectID: String) async {
        guard let repository,
              let subject = followUpSubjects.first(where: { $0.id == subjectID }),
              var updated = (commitments + resolvedCommitments).first(where: { $0.id == value.id }) else { return }
        updated.subjectID = subject.id
        updated.contextLabel = subject.name
        updated.area = subject.area
        updated.manuallyEditedFields.insert(.subject)
        updated.updatedAt = Date()
        updated.history.append(FollowUpHistoryEntry(kind: .edited, actor: .user, summary: "Moved to \(subject.name)"))
        await persistFollowUpMutation(updated, repository: repository)
    }

    func snoozeFollowUp(_ value: Commitment, until date: Date) async {
        guard let repository,
              date > Date(),
              var updated = commitments.first(where: { $0.id == value.id }) else { return }
        updated.snoozedUntil = date
        updated.setLifecycle(.snoozed, actor: .user)
        updated.snoozedUntil = date
        if let last = updated.history.indices.last {
            updated.history[last].summary = "Snoozed until \(date.formatted(date: .abbreviated, time: .shortened))"
        }
        await persistFollowUpMutation(updated, repository: repository)
    }

    func resetFollowUps() async {
        guard let repository else { return }
        do {
            try await repository.resetFollowUps()
            settingsStore.settings.followUpDisplay.selectedArea = nil
            settingsStore.settings.followUpDisplay.selectedTypeIDs = []
            settingsStore.settings.followUpDisplay.selectedSubjectIDs = []
            settingsStore.settings.followUpDisplay.selectedColorTokens = []
            settingsStore.settings.followUpDisplay.minimumPriority = 0
            settingsStore.settings.followUpDisplay.viewMode = .active
            settingsStore.settings.followUpDisplay.completedRailMode = .rail
            followUpOperationMessage = "Actions were reset. New activity will start a clean workspace."
            await refresh()
        } catch {
            followUpOperationMessage = error.localizedDescription
        }
    }

    func completeFollowUp(_ value: Commitment) async {
        guard let repository,
              var updated = commitments.first(where: { $0.id == value.id }) else { return }
        updated.setLifecycle(.completed, actor: .user)
        updated.completionActor = .user
        await persistFollowUpMutation(updated, repository: repository)
    }

    func dismissFollowUp(_ value: Commitment) async {
        guard let repository,
              var updated = commitments.first(where: { $0.id == value.id }) else { return }
        updated.setLifecycle(.dismissed, actor: .user)
        await persistFollowUpMutation(updated, repository: repository)
    }

    func restoreFollowUp(_ value: Commitment) async {
        guard let repository,
              var updated = commitments.first(where: { $0.id == value.id }) else { return }
        let now = Date()
        updated.setLifecycle(.active, actor: .user, now: now)
        updated.surfacedAt = now
        if let last = updated.history.indices.last {
            updated.history[last] = FollowUpHistoryEntry(kind: .restored, actor: .user, summary: "Restored", occurredAt: now)
        }
        await persistFollowUpMutation(updated, repository: repository)
    }

    func reopenFollowUp(_ value: Commitment) async {
        guard let repository,
              var updated = resolvedCommitments.first(where: { $0.id == value.id }) else { return }
        let now = Date()
        updated.setLifecycle(.active, actor: .user, now: now)
        updated.surfacedAt = now
        updated.completionActor = nil
        updated.completionEvidence = nil
        if let last = updated.history.indices.last {
            updated.history[last] = FollowUpHistoryEntry(kind: .reopened, actor: .user, summary: "Reopened", occurredAt: now)
        }
        await persistFollowUpMutation(updated, repository: repository)
    }

    private func persistFollowUpMutation(
        _ commitment: Commitment,
        repository: EncryptedSQLiteStore
    ) async {
        do {
            try await repository.saveCommitment(commitment)
            followUpOperationMessage = nil
            await refresh()
        } catch {
            followUpOperationMessage = error.localizedDescription
        }
    }

    func saveFollowUpSubject(_ subject: FollowUpSubject) async {
        guard let repository else { return }
        guard !FollowUpContextGrouper.isGenericSubjectName(subject.name) else {
            followUpOperationMessage = "Use a specific client, project, or activity as the subject."
            return
        }
        if let duplicate = followUpSubjects.first(where: {
            $0.id != subject.id && $0.name.localizedCaseInsensitiveCompare(subject.name) == .orderedSame
        }) {
            followUpOperationMessage = "The subject \(duplicate.name) already exists."
            return
        }
        var updatedSubject = subject
        if let selectedType = followUpTypes.first(where: { $0.id == updatedSubject.typeID }) {
            updatedSubject.area = selectedType.area
        } else {
            updatedSubject.typeID = FollowUpType.defaultID(for: updatedSubject.area)
        }
        let previous = followUpSubjects.first(where: { $0.id == subject.id })
        if let previous, previous.createdAt != subject.createdAt {
            followUpOperationMessage = "The subject \(previous.name) already exists."
            return
        }
        if let previous,
           previous.name.localizedCaseInsensitiveCompare(subject.name) != .orderedSame {
            updatedSubject.aliases.insert(previous.name)
        }
        do {
            try await repository.saveFollowUpSubject(updatedSubject)
            if let previous,
               previous.name != updatedSubject.name || previous.area != updatedSubject.area || previous.typeID != updatedSubject.typeID {
                let summary = previous.name != updatedSubject.name
                    ? "Subject renamed from \(previous.name) to \(updatedSubject.name)"
                    : "Subject type changed to \(typeName(for: updatedSubject.typeID))"
                for var commitment in (commitments + resolvedCommitments) where commitment.subjectID == updatedSubject.id {
                    commitment.contextLabel = updatedSubject.name
                    commitment.area = updatedSubject.area
                    commitment.manuallyEditedFields.insert(.subject)
                    commitment.updatedAt = Date()
                    commitment.history.append(FollowUpHistoryEntry(
                        kind: .edited,
                        actor: .user,
                        summary: summary
                    ))
                    try await repository.saveCommitment(commitment)
                }
            }
            await refresh()
        } catch {
            followUpOperationMessage = error.localizedDescription
        }
    }

    func saveFollowUpType(_ type: FollowUpType) async {
        guard let repository else { return }
        var updatedType = type
        updatedType.name = updatedType.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !updatedType.name.isEmpty else {
            followUpOperationMessage = "Add a name before saving this type."
            return
        }
        if let duplicate = followUpTypes.first(where: {
            $0.id != updatedType.id && $0.name.localizedCaseInsensitiveCompare(updatedType.name) == .orderedSame
        }) {
            followUpOperationMessage = "The type \(duplicate.name) already exists."
            return
        }
        let previous = followUpTypes.first(where: { $0.id == updatedType.id })
        updatedType.updatedAt = Date()
        do {
            try await repository.saveFollowUpType(updatedType)
            if let previous, previous.area != updatedType.area {
                for var subject in followUpSubjects where subject.typeID == updatedType.id {
                    subject.area = updatedType.area
                    subject.updatedAt = Date()
                    try await repository.saveFollowUpSubject(subject)
                    for var commitment in (commitments + resolvedCommitments) where commitment.subjectID == subject.id {
                        commitment.area = updatedType.area
                        commitment.updatedAt = Date()
                        commitment.history.append(FollowUpHistoryEntry(
                            kind: .edited,
                            actor: .user,
                            summary: "Type changed to \(updatedType.name)"
                        ))
                        try await repository.saveCommitment(commitment)
                    }
                }
            }
            followUpOperationMessage = nil
            await refresh()
        } catch {
            followUpOperationMessage = error.localizedDescription
        }
    }

    func deleteFollowUpType(_ type: FollowUpType) async {
        guard let repository, !type.isBuiltIn else { return }
        guard !followUpSubjects.contains(where: { $0.typeID == type.id }) else {
            followUpOperationMessage = "Move this type's subjects before deleting it."
            return
        }
        do {
            try await repository.deleteFollowUpType(id: type.id)
            settingsStore.settings.followUpDisplay.selectedTypeIDs.remove(type.id)
            followUpOperationMessage = nil
            await refresh()
        } catch {
            followUpOperationMessage = error.localizedDescription
        }
    }

    private func typeName(for identifier: String?) -> String {
        identifier.flatMap { id in followUpTypes.first(where: { $0.id == id })?.name } ?? "Uncategorized"
    }

    func mergeSubjects(sourceID: String, into targetID: String) async {
        guard sourceID != targetID,
              let repository,
              let source = followUpSubjects.first(where: { $0.id == sourceID }),
              var target = followUpSubjects.first(where: { $0.id == targetID }) else { return }
        let combinedCorrections = max(1, source.correctionCount + target.correctionCount)
        target.priorityBias = min(max(
            (source.priorityBias * Double(source.correctionCount) + target.priorityBias * Double(target.correctionCount))
                / Double(combinedCorrections),
            -3
        ), 3)
        target.correctionCount = source.correctionCount + target.correctionCount
        target.aliases.formUnion(source.aliases)
        target.aliases.insert(source.name)
        target.updatedAt = Date()
        do {
            for var commitment in (commitments + resolvedCommitments)
                where commitment.subjectID == sourceID || commitment.subjectID == targetID {
                let moved = commitment.subjectID == sourceID
                if moved {
                    commitment.subjectID = target.id
                    commitment.contextLabel = target.name
                    commitment.area = target.area
                    commitment.manuallyEditedFields.insert(.subject)
                    commitment.history.append(FollowUpHistoryEntry(
                        kind: .edited,
                        actor: .user,
                        summary: "Subject merged into \(target.name)"
                    ))
                }
                commitment.displayPriorityScore = FollowUpPrioritizer.personalizedScore(
                    aiScore: commitment.aiPriorityScore,
                    subject: target
                )
                commitment.isPriority = commitment.priorityScore >= 8
                commitment.updatedAt = Date()
                try await repository.saveCommitment(commitment)
            }
            try await repository.saveFollowUpSubject(target)
            try await repository.deleteFollowUpSubject(id: sourceID)
            if settingsStore.settings.followUpDisplay.selectedSubjectIDs.remove(sourceID) != nil {
                settingsStore.settings.followUpDisplay.selectedSubjectIDs.insert(targetID)
            }
            await refresh()
        } catch {
            followUpOperationMessage = error.localizedDescription
        }
    }

    func mergeFollowUps(
        ids: [UUID],
        targetID: UUID? = nil,
        allowUnrelated: Bool = false,
        preparedDraft: FollowUpMergeDraft? = nil
    ) async {
        guard let repository else { return }
        pendingFollowUpMergeConfirmation = nil
        let selection = FollowUpMergeResolver.activeSelection(ids: ids, from: commitments)
        let values = selection.commitments
        guard values.count >= 2 else { return }
        let participatingIDs = selection.sourceIDs
        guard preparedDraft != nil || (try? settingsStore.apiKey()) != nil else {
            followUpOperationMessage = "Add a valid OpenAI API key before merging Actions."
            return
        }
        let target = targetID.flatMap { id in values.first(where: { $0.id == id }) } ?? values[0]
        let subject = target.subjectID.flatMap { id in followUpSubjects.first(where: { $0.id == id }) }
        followUpOperationMessage = "Merging \(values.count) Actions…"
        do {
            let draft: FollowUpMergeDraft
            if let preparedDraft {
                draft = preparedDraft
            } else {
                guard let key = try settingsStore.apiKey() else {
                    throw OpenAIClientError.missingAPIKey
                }
                draft = try await ai.mergeFollowUps(
                    values,
                    subject: subject,
                    outputLanguage: settingsStore.outputLanguagePrompt(),
                    apiKey: key
                )
            }
            if !allowUnrelated,
               let warning = FollowUpMergeResolver.confirmationWarning(
                   for: draft,
                   selection: selection,
                   targetID: target.id
               ) {
                pendingFollowUpMergeConfirmation = warning
                followUpOperationMessage = nil
                return
            }
            let now = Date()
            var merged = FollowUpMergeResolver.applyingAIContent(
                draft,
                to: target,
                preserving: values
            )
            guard !merged.action.isEmpty else { throw OpenAIClientError.malformedStructuredOutput }
            let preserved = FollowUpMergeResolver.mergedFields(from: values)
            if let preserved,
               preserved.explicitDueAt != nil,
               preserved.dueSource == .user || preserved.dueSource == .explicitEvidence {
                merged.explicitDueAt = preserved.explicitDueAt
                merged.suggestedReviewAt = nil
                merged.dueSource = preserved.dueSource
                merged.dueConfidence = preserved.dueConfidence
            } else {
                let explicitDue = draft.dueSource == .explicitEvidence ? draft.dueAt : nil
                merged.explicitDueAt = explicitDue
                merged.suggestedReviewAt = nil
                merged.dueSource = explicitDue == nil ? nil : .explicitEvidence
                merged.dueConfidence = explicitDue == nil ? nil : draft.confidence
            }
            if merged.dueSource == .user { merged.manuallyEditedFields.insert(.dueDate) }

            merged.aiPriorityScore = draft.priorityScore
            merged.userPriorityScore = preserved?.userPriorityScore
            if merged.userPriorityScore != nil {
                merged.manuallyEditedFields.insert(.priority)
                merged.priorityReason = preserved?.priorityReason ?? merged.priorityReason
            }

            var mergedSubject = merged.subjectID.flatMap { id in followUpSubjects.first(where: { $0.id == id }) }
            if !target.manuallyEditedFields.contains(.subject) {
                let sourceEventIDs = Set(values.flatMap { [$0.eventID] + $0.linkedEventIDs })
                let evidenceEvent = events
                    .filter { sourceEventIDs.contains($0.id) }
                    .max { $0.startedAt < $1.startedAt }
                let concreteName = FollowUpContextGrouper.specificSubjectLabel(
                    suggested: draft.contextLabel,
                    action: draft.action,
                    context: [draft.summary, draft.details, values.map(\.action).joined(separator: " ")]
                        .filter { !$0.isEmpty }
                        .joined(separator: " "),
                    event: evidenceEvent,
                    area: draft.area
                )
                let resolution = FollowUpContextGrouper.resolveOrCreateSubject(
                    named: concreteName,
                    area: draft.area,
                    in: followUpSubjects
                )
                if resolution.wasCreated { try await repository.saveFollowUpSubject(resolution.subject) }
                merged.subjectID = resolution.subject.id
                merged.contextLabel = resolution.subject.name
                merged.area = resolution.subject.area
                mergedSubject = resolution.subject
            }
            merged.displayPriorityScore = FollowUpPrioritizer.personalizedScore(
                aiScore: merged.aiPriorityScore,
                subject: mergedSubject
            )
            merged.isPriority = merged.priorityScore >= 8
            merged.linkedEventIDs = preserved?.linkedEventIDs
                ?? Array(Set(values.flatMap { [$0.eventID] + $0.linkedEventIDs }))
            merged.completionEvidence = preserved?.completionEvidence
            merged.evidenceHint = preserved?.evidenceHint
            merged.surfacedAt = preserved?.surfacedAt ?? values.map(\.surfacedAt).max() ?? now
            merged.updatedAt = now
            merged.lifecycle = .active
            merged.state = .needsAttention
            merged.history = preserved?.history ?? values.flatMap(\.history).sorted { $0.occurredAt < $1.occurredAt }
            let sourceTitles = values.map(\.action).joined(separator: " • ")
            let sourceSubjects = Set(values.map { $0.contextLabel ?? "Uncategorized" })
                .sorted()
                .joined(separator: ", ")
            merged.history.append(FollowUpHistoryEntry(
                kind: .merged,
                actor: .iriz,
                summary: "Merged \(values.count) Actions from \(sourceSubjects): \(sourceTitles)",
                occurredAt: now
            ))
            try await repository.replaceCommitments(with: merged, deletingSourceIDs: participatingIDs)
            if FollowUpIndicatorOutcomePolicy.shouldHighlight(previous: target, updated: merged, source: .iriz) {
                indicatorActivities.emitSuccess(context: .followUp)
            }
            followUpOperationMessage = nil
            await refresh()
        } catch {
            followUpOperationMessage = error.localizedDescription
        }
    }

    func confirmPendingFollowUpMerge() async {
        guard let pending = pendingFollowUpMergeConfirmation else { return }
        pendingFollowUpMergeConfirmation = nil
        await mergeFollowUps(
            ids: pending.sourceIDs,
            targetID: pending.targetID,
            allowUnrelated: true,
            preparedDraft: pending.draft
        )
    }

    func cancelPendingFollowUpMerge() {
        pendingFollowUpMergeConfirmation = nil
        followUpOperationMessage = "Merge cancelled. Both Actions were kept."
    }

    func mergeAllActiveFollowUps(in subjectID: String) async {
        let ids = commitments
            .filter { $0.lifecycle == .active && $0.subjectID == subjectID }
            .map(\.id)
        await mergeFollowUps(ids: ids, targetID: ids.first)
    }

    func exportPayload(for commitment: Commitment) -> FollowUpExportPayload {
        let eventID = commitment.linkedEventIDs.last ?? commitment.eventID
        let event = events.first(where: { $0.id == eventID })
        let notes = [commitment.summary, commitment.details, commitment.rationale]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        return FollowUpExportPayload(
            title: commitment.action,
            notes: notes.isEmpty ? nil : notes,
            priority: commitment.priorityScore,
            dueDate: commitment.dueAt,
            sourceURL: event?.urls.first
        )
    }

    func addFollowUpToReminders(_ value: Commitment) async {
        guard let repository,
              var updated = (commitments + resolvedCommitments).first(where: { $0.id == value.id }) else { return }
        do {
            let receipt = try await followUpExporter.addToReminders(exportPayload(for: updated))
            updated.history.append(FollowUpHistoryEntry(
                kind: .exported,
                actor: .user,
                summary: "Added to Reminders — \(receipt.calendarTitle)"
            ))
            updated.updatedAt = Date()
            try await repository.saveCommitment(updated)
            followUpOperationMessage = "Added to \(receipt.calendarTitle)."
            await refresh()
        } catch {
            followUpOperationMessage = error.localizedDescription
        }
    }

    func copyFollowUp(_ value: Commitment) {
        let text = FollowUpExportService.plainText(for: exportPayload(for: value))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        followUpOperationMessage = "Copied Action."
    }

    func mediaData(identifier: String) async -> Data? {
        guard let mediaStore else { return nil }
        return try? await mediaStore.read(identifier: identifier)
    }

    func openEvent(_ id: UUID) {
        openMainWindow()
        if let event = events.first(where: { $0.id == id }) {
            presentedEvent = event
            return
        }
        Task { [weak self] in
            guard let self, let repository else { return }
            presentedEvent = try? await repository.event(id: id)
        }
    }

    func closeEvent() {
        presentedEvent = nil
    }

    func openMainWindow(section: MainSection? = nil) {
        if let section { selectedSection = section }
        NotificationCenter.default.post(name: .irizOpenMainWindow, object: nil)
    }

    func openSettings(category: SettingsCategory? = nil) {
        if let category { selectedSettingsCategory = category }
        openMainWindow(section: .settings)
    }

    func testAPIKey(_ candidate: String) async {
        settingsStore.setAPIKeyState(.testing)
        do {
            try await ai.validateAPIKey(candidate)
            try settingsStore.saveAPIKey(candidate)
            settingsStore.setAPIKeyState(.valid)
            if secureStorageState == .ready {
                captureHealth = configuredCaptureHealth
            }
            await retryPending()
        } catch {
            if let clientError = error as? OpenAIClientError, clientError.isInvalidCredential {
                settingsStore.setAPIKeyState(.invalid(clientError.localizedDescription))
            } else if let keychainError = error as? KeychainStoreError {
                settingsStore.setAPIKeyState(
                    keychainError.requiresUserApproval
                        ? .needsApproval
                        : .invalid(keychainError.localizedDescription)
                )
            } else {
                let previousState: APIKeyState = (try? settingsStore.apiKey()) == nil ? .missing : .saved
                settingsStore.setAPIKeyState(previousState)
            }
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                indicatorActivities.emitAPIFailure(context: .credentials)
            }
            captureHealth = configuredCaptureHealth
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

    func exportMemory(format: ExportFormat) async {
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
            var shouldHighlightFollowUp = false
            // Keep one immutable creation policy for the entire request. If the
            // user changes the menu while the network call is in flight, the
            // returned tiles still retain the level that shaped their creation.
            let requestedDetailLevel = settingsStore.settings.followUpDetailLevel
            let candidateProbe = ActivityEvent(
                startedAt: observation.capturedAt,
                endedAt: observation.capturedAt,
                kind: observation.isMeeting ? .meeting : .context,
                status: .observed,
                importance: .normal,
                title: observation.windowTitle ?? observation.applicationName ?? "Observed context",
                summary: String(observation.text.prefix(1_500)),
                details: [observation.applicationName, observation.url?.absoluteString].compactMap { $0 }.joined(separator: " "),
                urls: [observation.url].compactMap { $0 },
                sourceApplications: [observation.applicationName].compactMap { $0 },
                confidence: 0.6
            )
            let candidateFollowUps = CommitmentLinker.relatedCandidates(
                for: candidateProbe,
                among: commitments.filter { $0.lifecycle == .active || $0.lifecycle == .snoozed },
                events: events,
                subjects: followUpSubjects,
                maximumCount: 8
            )
            let interpretation = try await ai.interpret(
                observation: observation,
                imageData: observation.source == .screen ? mediaData : nil,
                outputLanguage: settingsStore.outputLanguagePrompt(),
                followUpDetailLevel: requestedDetailLevel,
                knownFollowUpContexts: FollowUpContextGrouper.contextLabels(from: commitments),
                followUpCandidates: candidateFollowUps,
                knownFollowUpSubjects: followUpSubjects,
                apiKey: key
            )
            let interpretedEvent = interpretation.event
                ?? (interpretation.commitments.isEmpty ? nil : candidateProbe)
            if (interpretation.shouldCreateEvent || !interpretation.commitments.isEmpty),
               let event = interpretedEvent {
                let localConsolidation = await consolidate(event)
                let shouldRefine = interpretation.event != nil && (localConsolidation.importance >= .important
                    || localConsolidation.status == .completed
                    || localConsolidation.kind == .meeting
                    || !interpretation.commitments.isEmpty)
                let consolidated: ActivityEvent
                if shouldRefine {
                    do {
                        consolidated = try await ai.refine(
                            event: localConsolidation,
                            outputLanguage: settingsStore.outputLanguagePrompt(),
                            apiKey: key
                        )
                    } catch {
                        handleProcessingError(error, context: Self.indicatorContext(for: observation))
                        consolidated = localConsolidation
                    }
                } else {
                    consolidated = localConsolidation
                }
                try await repository.saveEvent(consolidated)
                var openCommitments = try await repository.commitments(includingClosed: false)
                let locallyRelated = CommitmentLinker.relatedCandidates(
                    for: consolidated,
                    among: openCommitments,
                    // `relatedCandidates(for:)` indexes the current event itself.
                    // Passing it twice previously exposed live duplicate IDs.
                    events: events,
                    subjects: followUpSubjects,
                    maximumCount: 8
                )
                for existing in locallyRelated {
                    if let linked = CommitmentLinker.linking(existing, to: consolidated) {
                        try await repository.saveCommitment(linked)
                        shouldHighlightFollowUp = shouldHighlightFollowUp || FollowUpIndicatorOutcomePolicy.shouldHighlight(
                            previous: existing,
                            updated: linked,
                            source: .iriz
                        )
                        if let index = openCommitments.firstIndex(where: { $0.id == linked.id }) {
                            openCommitments[index] = linked
                        }
                    }
                }
                let allowedCandidateIDs = Set(candidateFollowUps.map(\.id))
                for draft in interpretation.commitments {
                    if draft.operation != .create,
                       let existingID = draft.existingCommitmentID,
                       allowedCandidateIDs.contains(existingID),
                       let index = openCommitments.firstIndex(where: { $0.id == existingID }) {
                        let previous = openCommitments[index]
                        var updated = CommitmentLinker.applyingNonDestructiveTextUpdate(
                            draft,
                            to: openCommitments[index]
                        )
                        updated.linkedEventIDs = Array(Set(updated.linkedEventIDs + [consolidated.id]))
                        updated.confidence = max(updated.confidence, draft.confidence)
                        updated.updatedAt = Date()
                        if !updated.manuallyEditedFields.contains(.owner), !draft.owner.isEmpty { updated.owner = draft.owner }
                        if !updated.manuallyEditedFields.contains(.priority) {
                            let subject = updated.subjectID.flatMap { id in followUpSubjects.first(where: { $0.id == id }) }
                            updated = FollowUpPrioritizer.applyingAIPriority(
                                draft.priorityScore,
                                reason: draft.priorityReason,
                                to: updated,
                                subject: subject
                            )
                        }
                        if !updated.manuallyEditedFields.contains(.dueDate) {
                            let explicitDue = draft.dueSource == .explicitEvidence ? draft.explicitDueAt : nil
                            updated.explicitDueAt = explicitDue
                            updated.suggestedReviewAt = nil
                            updated.dueSource = explicitDue == nil ? nil : .explicitEvidence
                            updated.dueConfidence = explicitDue == nil ? nil : draft.confidence
                        }
                        if !updated.manuallyEditedFields.contains(.subject) {
                            let concreteName = FollowUpContextGrouper.specificSubjectLabel(
                                suggested: draft.contextLabel,
                                action: updated.action,
                                context: [draft.summary, draft.details, consolidated.searchableText]
                                    .filter { !$0.isEmpty }
                                    .joined(separator: " "),
                                event: consolidated,
                                area: draft.area
                            )
                            let resolution = FollowUpContextGrouper.resolveOrCreateSubject(
                                named: concreteName,
                                area: draft.area,
                                in: followUpSubjects
                            )
                            updated.subjectID = resolution.subject.id
                            updated.contextLabel = resolution.subject.name
                            updated.area = resolution.subject.area
                            if resolution.wasCreated { try await repository.saveFollowUpSubject(resolution.subject) }
                        }
                        if draft.operation == .complete,
                           draft.confidence >= 0.82,
                           draft.evidenceStrength == .strong || draft.evidenceStrength == .explicit {
                            updated.setLifecycle(.completed, actor: .iriz)
                            updated.completionActor = .iriz
                            updated.completionEvidence = FollowUpCompletionEvidence(
                                eventID: consolidated.id,
                                summary: draft.rationale.isEmpty ? consolidated.summary : draft.rationale,
                                confidence: draft.confidence,
                                strength: draft.evidenceStrength,
                                capturedAt: consolidated.startedAt
                            )
                        } else {
                            updated.evidenceHint = draft.evidenceStrength == .weak ? draft.rationale : nil
                            updated.history.append(FollowUpHistoryEntry(
                                kind: .evidence,
                                actor: .iriz,
                                summary: draft.rationale.isEmpty ? "New supporting evidence" : draft.rationale,
                                eventID: consolidated.id
                            ))
                        }
                        try await repository.saveCommitment(updated)
                        shouldHighlightFollowUp = shouldHighlightFollowUp || FollowUpIndicatorOutcomePolicy.shouldHighlight(
                            previous: previous,
                            updated: updated,
                            source: .iriz
                        )
                        openCommitments[index] = updated
                        continue
                    }

                    guard draft.operation == .create,
                          draft.confidence >= 0.60 || draft.explicitDueAt != nil,
                          !draft.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    let concreteName = FollowUpContextGrouper.specificSubjectLabel(
                        suggested: draft.contextLabel,
                        action: draft.action,
                        context: [draft.summary, draft.details, consolidated.searchableText]
                            .filter { !$0.isEmpty }
                            .joined(separator: " "),
                        event: consolidated,
                        area: draft.area
                    )
                    let resolution = FollowUpContextGrouper.resolveOrCreateSubject(
                        named: concreteName,
                        area: draft.area,
                        in: followUpSubjects
                    )
                    if resolution.wasCreated { try await repository.saveFollowUpSubject(resolution.subject) }
                    let personalizedPriority = FollowUpPrioritizer.personalizedScore(
                        aiScore: draft.priorityScore,
                        subject: resolution.subject
                    )
                    let proposed = Commitment(
                        eventID: consolidated.id,
                        owner: draft.owner,
                        action: draft.action,
                        rationale: draft.rationale,
                        explicitDueAt: draft.dueSource == .explicitEvidence ? draft.explicitDueAt : nil,
                        suggestedReviewAt: nil,
                        contextLabel: resolution.subject.name,
                        confidence: draft.confidence,
                        state: .needsAttention,
                        summary: draft.summary,
                        details: draft.details,
                        lifecycle: .active,
                        subjectID: resolution.subject.id,
                        area: resolution.subject.area,
                        origin: .iriz,
                        detailLevelAtCreation: requestedDetailLevel,
                        aiPriorityScore: draft.priorityScore,
                        displayPriorityScore: personalizedPriority,
                        priorityReason: draft.priorityReason,
                        surfacedAt: consolidated.startedAt,
                        dueSource: draft.dueSource == .explicitEvidence && draft.explicitDueAt != nil ? .explicitEvidence : nil,
                        dueConfidence: draft.dueSource == .explicitEvidence && draft.explicitDueAt != nil ? draft.confidence : nil,
                        history: [FollowUpHistoryEntry(
                            kind: .created,
                            actor: .iriz,
                            summary: draft.rationale.isEmpty ? "Detected by iriz" : draft.rationale,
                            occurredAt: consolidated.startedAt,
                            eventID: consolidated.id
                        )]
                    )
                    try await repository.saveCommitment(proposed)
                    shouldHighlightFollowUp = shouldHighlightFollowUp || FollowUpIndicatorOutcomePolicy.shouldHighlight(
                        previous: nil,
                        updated: proposed,
                        source: .iriz
                    )
                    if let index = openCommitments.firstIndex(where: { $0.id == proposed.id }) {
                        openCommitments[index] = proposed
                    } else {
                        openCommitments.append(proposed)
                    }
                }
                if consolidated.importance >= .important { latestInsight = consolidated }
                if shouldHighlightFollowUp {
                    indicatorActivities.emitSuccess(context: .followUp)
                }
            }
            try await repository.markObservationProcessed(id: observation.id, at: Date())
            pendingCount = max(0, pendingCount - 1)
            await refresh()
        } catch {
            // The encrypted observation remains pending and can be retried until its 24-hour expiry.
            handleProcessingError(error, context: Self.indicatorContext(for: observation))
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

    private var hasPersistentIndicatorIssue: Bool {
        switch configuredCaptureHealth {
        case .permissionNeeded, .error: true
        case .paused, .observing, .listening, .observingAndListening, .waitingForSchedule,
             .meeting, .meetingAndListening, .processing: false
        }
    }

    private func handleProcessingError(_ error: Error, context: IndicatorActivityContext) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        if let clientError = error as? OpenAIClientError {
            if clientError.isInvalidCredential {
                settingsStore.setAPIKeyState(.invalid(clientError.localizedDescription))
                captureHealth = .error("OpenAI credentials need attention.")
            } else {
                indicatorActivities.emitAPIFailure(context: context)
            }
            return
        }
        if error is URLError {
            indicatorActivities.emitAPIFailure(context: context)
            return
        }
        captureHealth = .error(error.localizedDescription)
    }

    private static func indicatorContext(for observation: Observation) -> IndicatorActivityContext {
        if observation.isMeeting { return .meeting }
        return switch observation.source {
        case .screen: .screen
        case .ambientAudio: .voice
        case .meetingMicrophone, .meetingSystemAudio: .meeting
        case .manualNote: .followUp
        }
    }

    private var configuredCaptureHealth: CaptureHealth {
        CaptureHealthResolver.resolve(CaptureHealthInputs(
            settings: settingsStore.settings,
            secureStorageState: secureStorageState,
            apiKeyState: settingsStore.apiKeyState,
            screenPermission: PermissionService.screenCaptureState(),
            accessibilityPermission: PermissionService.accessibilityState(),
            microphonePermission: PermissionService.microphoneState(),
            screenFailureMessage: screenCaptureFailureMessage,
            audioFailureMessage: audioCaptureFailureMessage,
            screenVisibility: indicatorSnapshot.screenVisibility,
            meetingContextDetected: lastScreenContext?.isMeeting == true,
            now: Date()
        ))
    }
}
