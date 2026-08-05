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

    private struct PendingOpenAIBlockPersistence: Sendable {
        let errorKind: AnalysisErrorKind
        let errorMessage: String
        let occurredAt: Date
    }

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
    @Published private(set) var localIntelligenceStatus: LocalIntelligenceStatus = .fallback(.unavailable)

    let settingsStore = SettingsStore.shared
    private var repository: EncryptedSQLiteStore?
    private var mediaStore: EncryptedMediaStore?
    private var searchService: LocalSearchService?
    let indicatorActivities: IndicatorActivityStore
    private let ai: any AIProviding
    private let usageRecorder: PersistentOpenAIUsageRecorder
    private let optimizationRecorder: PersistentOptimizationTelemetryRecorder
    private let localGate: AppleFoundationModelGate
    private let localSpeechAnalyzer: LocalSpeechAnalyzerQualificationHarness
    private let screenCapture = ScreenCaptureService()
    private let screenBatcher = ScreenObservationBatcher()
    private let ocr = VisionOCRService()
    private let audioTranscriptBatcher = AudioTranscriptBatcher()
    private let analysisMutationGate = AsyncOperationGate()
    private let screenVisibilityGate = AsyncOperationGate()
    private let audioCapture = AudioCaptureService()
    private let systemAudioCapture = SystemAudioCaptureService()
    private let notifications = NotificationService()
    private let followUpExporter = FollowUpExportService()
    private var bootstrapTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    private var audioConfigurationTask: Task<Void, Never>?
    private var audioConfigurationGeneration: UUID?
    private var privacyCleanupTask: Task<Void, Never>?
    private var openAIBlockPersistenceTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingOpenAIBlockPersistence: [UUID: PendingOpenAIBlockPersistence] = [:]
    private var lastScreenJPEG: Data?
    private var lastScreenContext: ActiveContext?
    private var lastMeetingEndedAt: Date?
    private var screenContextVisibility: ScreenContextVisibility = .unavailable
    private var screenCaptureFailureMessage: String?
    private var audioCaptureFailureMessage: String?
    private var isComposingNewAssistantConversation = false
    private var indicatorSnapshotCancellable: AnyCancellable?
    private var apiKeyStateCancellable: AnyCancellable?
    private var intelligenceSettingsCancellable: AnyCancellable?
    private var isDrainingScreenAnalysisQueue = false
    private var isDrainingAudioAnalysisQueue = false
    private var isDrainingRefinementQueue = false
    private var screenAnalysisDrainRequested = false
    private var audioAnalysisDrainRequested = false
    private var refinementDrainRequested = false
    private var activeScreenAnalysisTask: Task<Void, Never>?
    private var activeAudioAnalysisTask: Task<Void, Never>?
    private var activeRefinementTask: Task<Void, Never>?
    private var activeInteractiveWorkflowCount = 0
    private var interactiveWorkflowWaiters: [CheckedContinuation<Void, Never>] = []
    private var capturePrivacyBoundary = CapturePrivacyBoundary()
    private let captureCommitFence = CaptureCommitFence()
    /// Set by any 401/403/project-spend failure and restored from the durable
    /// queues on launch. Only an explicit key validation resumes cloud work.
    private var isOpenAIWorkBlocked = false
    private var isPreparingForTermination = false
    private var hasQuiescedForTermination = false

    init(
        ai: (any AIProviding)? = nil,
        indicatorActivities: IndicatorActivityStore? = nil
    ) {
        let activityStore = indicatorActivities ?? IndicatorActivityStore()
        let usageRecorder = PersistentOpenAIUsageRecorder()
        let optimizationRecorder = PersistentOptimizationTelemetryRecorder()
        self.indicatorActivities = activityStore
        self.usageRecorder = usageRecorder
        self.optimizationRecorder = optimizationRecorder
        self.localGate = AppleFoundationModelGate(telemetryHandler: { record in
            await optimizationRecorder.record(record)
        }, localEventDraftPolicy: OptimizationRuntimePolicy.localEventDraftPolicy)
        self.localSpeechAnalyzer = LocalSpeechAnalyzerQualificationHarness(
            configuration: LocalSpeechAnalyzerHarnessConfiguration(
                isEnabled: OptimizationRuntimePolicy.localSpeechEnabled
                    && !SpeechAnalyzerQualificationRegistry.embeddedApprovedProfiles.isEmpty,
                allowedLanguageCodes: ["en", "fr"],
                requiresApprovedProfile: true,
                approvedProfiles: SpeechAnalyzerQualificationRegistry.embeddedApprovedProfiles
            )
        )
        self.ai = ai ?? OpenAIClient(indicatorActivities: activityStore, usageRecorder: usageRecorder)
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
        self.intelligenceSettingsCancellable = settingsStore.$settings
            .map { "\($0.outputLanguageTag)|\($0.optimizationPhase.rawValue)" }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task { await self?.refreshLocalIntelligenceStatus(prewarm: true) }
            }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in AppState.shared.pause() }
        }

        bootstrapTask = Task { [weak self] in
            await self?.bootstrap()
        }
    }

    deinit {
        bootstrapTask?.cancel()
        maintenanceTask?.cancel()
        audioConfigurationTask?.cancel()
        privacyCleanupTask?.cancel()
        openAIBlockPersistenceTasks.values.forEach { $0.cancel() }
        audioCapture.stop(flushPendingSegment: false)
        let recorder = usageRecorder
        let optimizationRecorder = optimizationRecorder
        let audioTranscriptBatcher = audioTranscriptBatcher
        Task {
            await audioTranscriptBatcher.cancelAndDrain()
            await recorder.flush()
            await optimizationRecorder.flush()
        }
    }

    func bootstrap() async {
        guard !Task.isCancelled, !isPreparingForTermination else { return }
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
        guard !Task.isCancelled, !isPreparingForTermination else { return }
        await refresh()
        guard !Task.isCancelled, !isPreparingForTermination else { return }
        await cleanup()
        guard !Task.isCancelled, !isPreparingForTermination else { return }
        await refreshLocalIntelligenceStatus(prewarm: true)
        guard !Task.isCancelled, !isPreparingForTermination else { return }
        await screenBatcher.start(
            telemetryHandler: { [optimizationRecorder = self.optimizationRecorder] record in
                await optimizationRecorder.record(record)
            },
            handler: { @Sendable batch in await AppState.shared.processScreenBatch(batch) }
        )
        await audioTranscriptBatcher.start { @Sendable batch in
            await AppState.shared.processAudioTranscriptBatch(batch)
        }
        guard !Task.isCancelled, !isPreparingForTermination else {
            await screenBatcher.cancelAndDrain()
            _ = await audioTranscriptBatcher.cancelAndDrain()
            return
        }
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
            telemetryHandler: { [optimizationRecorder = self.optimizationRecorder] record in
                await optimizationRecorder.record(record)
            },
            handler: { @Sendable frame in
                await AppState.shared.processScreenFrame(frame)
            }
        )
        guard !Task.isCancelled, !isPreparingForTermination else {
            await screenCapture.stop()
            await screenBatcher.cancelAndDrain()
            _ = await audioTranscriptBatcher.cancelAndDrain()
            return
        }
        configureAudio()
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                await self.maintenanceTick()
            }
        }
        if secureStorageState == .ready,
           !settingsStore.settings.isPaused,
           !isOpenAIWorkBlocked {
            await retryPending()
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
            await usageRecorder.attach(repository: stores.0)
            await optimizationRecorder.attach(repository: stores.0)
            isOpenAIWorkBlocked = try await stores.0.hasCredentialBlockedOpenAIJobs()
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
            if isOpenAIWorkBlocked {
                settingsStore.setAPIKeyState(.invalid(Self.restoredOpenAIBlockMessage))
                captureHealth = .error(Self.restoredOpenAIBlockMessage)
            }
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
        let wasPaused = settingsStore.settings.isPaused
        if !paused,
           !settingsStore.settings.screenCaptureEnabled,
           settingsStore.settings.audioMode == .off {
            settingsStore.settings.screenCaptureEnabled = true
        }
        settingsStore.settings.isPaused = paused
        if paused {
            if !wasPaused {
                capturePrivacyBoundary.invalidate()
                captureCommitFence.invalidate([.screen, .audio])
            }
            if isEnrollingVoice {
                isEnrollingVoice = false
                voiceEnrollmentMessage = "Voice enrollment was cancelled while Iriz was paused."
            }
            audioCapture.stop(flushPendingSegment: false)
            schedulePrivacyCleanup()
        } else {
            guard secureStorageState == .ready else {
                captureHealth = .permissionNeeded("Keychain access")
                return
            }
            // The cleanup task owns producer restart and queue retry. Starting a
            // new microphone callback before its final purge could mix content
            // from opposite sides of the pause boundary.
            guard privacyCleanupTask == nil else {
                captureHealth = configuredCaptureHealth
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
        guard AudioCaptureAdmissionPolicy.allowsCapture(
            isPreparingForTermination: isPreparingForTermination,
            isPaused: settingsStore.settings.isPaused,
            screenVisibility: screenContextVisibility,
            privacyCleanupInProgress: privacyCleanupTask != nil
        ) else {
            // Fail closed across private/pause/termination boundaries. This guard
            // is evaluated synchronously on MainActor before any new microphone
            // callback can be installed by a concurrent settings change.
            audioCapture.stop(flushPendingSegment: false)
            scheduleAudioConfigurationWork { app in
                await app.systemAudioCapture.stop(flushPendingSegment: false)
            }
            return
        }
        guard secureStorageState == .ready else {
            audioCapture.stop(flushPendingSegment: false)
            scheduleAudioConfigurationWork { app in
                await app.systemAudioCapture.stop(flushPendingSegment: false)
            }
            captureHealth = configuredCaptureHealth
            return
        }
        guard settingsStore.settings.isAudioActiveNow else {
            audioCapture.stop(flushPendingSegment: false)
            scheduleAudioConfigurationWork { app in
                await app.systemAudioCapture.stop(flushPendingSegment: false)
            }
            audioCaptureFailureMessage = nil
            captureHealth = configuredCaptureHealth
            return
        }
        guard PermissionService.microphoneState() == .granted else {
            audioCapture.stop(flushPendingSegment: false)
            scheduleAudioConfigurationWork { app in
                await app.systemAudioCapture.stop(flushPendingSegment: false)
            }
            audioCaptureFailureMessage = nil
            captureHealth = configuredCaptureHealth
            return
        }
        do {
            let audioBoundaryToken = capturePrivacyBoundary.token
            try audioCapture.start { @Sendable wavData, duration in
                await AppState.shared.processAudio(
                    wavData,
                    voicedDuration: duration,
                    captureBoundaryToken: audioBoundaryToken
                )
            }
            audioCaptureFailureMessage = nil
            captureHealth = configuredCaptureHealth
            if settingsStore.settings.meetingDetectionEnabled, lastScreenContext?.isMeeting == true {
                let meetingContext = lastScreenContext
                scheduleAudioConfigurationWork { app in
                    await app.startSystemAudio(for: meetingContext)
                }
            } else {
                scheduleAudioConfigurationWork { app in
                    await app.systemAudioCapture.stop()
                }
            }
        } catch {
            audioCaptureFailureMessage = "Microphone observation is unavailable."
            captureHealth = configuredCaptureHealth
            scheduleAudioConfigurationWork { app in
                await app.systemAudioCapture.stop(flushPendingSegment: false)
            }
        }
    }

    private func scheduleAudioConfigurationWork(
        _ operation: @escaping @MainActor (AppState) async -> Void
    ) {
        audioConfigurationTask?.cancel()
        let generation = UUID()
        audioConfigurationGeneration = generation
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self, !self.isPreparingForTermination else { return }
            await operation(self)
            guard self.audioConfigurationGeneration == generation else { return }
            self.audioConfigurationTask = nil
            self.audioConfigurationGeneration = nil
        }
        audioConfigurationTask = task
    }

    private func schedulePrivacyCleanup() {
        guard !isPreparingForTermination, privacyCleanupTask == nil else { return }
        privacyCleanupTask = Task<Void, Never> { @MainActor [weak self] in
            guard let self, !self.isPreparingForTermination else { return }
            // Stop every producer before awaiting a cloud worker, then place the
            // final batch/job purge after those workers. Nothing can submit a late
            // transcript or OCR batch beyond this fence.
            let audioConfiguration = self.audioConfigurationTask
            audioConfiguration?.cancel()
            self.audioConfigurationTask = nil
            self.audioConfigurationGeneration = nil
            await audioConfiguration?.value
            await self.screenCapture.invalidatePendingFramesAndWait()
            await self.audioCapture.stopAndDrain(
                flushPendingSegment: false,
                cancelCallbacks: true
            )
            await self.systemAudioCapture.stop(flushPendingSegment: false)
            let screenTask = self.activeScreenAnalysisTask
            let audioTask = self.activeAudioAnalysisTask
            screenTask?.cancel()
            audioTask?.cancel()
            await screenTask?.value
            await audioTask?.value
            await self.screenBatcher.cancelAndDrain()
            await self.cancelPendingAudioTranscriptBatch()
            try? await self.repository?.discardPendingAnalysisJobs(
                sources: [.screen, .ambientAudio, .meetingMicrophone, .meetingSystemAudio],
                processedAt: Date()
            )
            if let repository = self.repository {
                self.pendingCount = (try? await repository.pendingAnalysisJobCount()) ?? self.pendingCount
            }
            self.privacyCleanupTask = nil
            if !self.settingsStore.settings.isPaused, !self.isPreparingForTermination {
                self.configureAudio()
                await self.retryPending()
            }
        }
    }

    func updateScreenVisibility(_ visibility: ScreenContextVisibility) async {
        // ScreenCaptureKit can report visibility from several awaited revalidation
        // points. Serialize transitions so a quick private -> available change
        // cannot restart producers before the private purge has completed.
        await screenVisibilityGate.acquire()
        defer { screenVisibilityGate.release() }
        // Set the boundary before awaiting cancellation. A dispatcher task that
        // was already in flight will then be rejected by processScreenFrame.
        let previousVisibility = screenContextVisibility
        // An unavailable AX/screen context stops screen work only. The microphone
        // keeps its valid token; private contexts invalidate both modalities.
        if visibility != .available, visibility != previousVisibility {
            captureCommitFence.invalidate([.screen])
            if visibility == .private {
                capturePrivacyBoundary.invalidate()
                captureCommitFence.invalidate([.audio])
            }
        }
        screenContextVisibility = visibility
        indicatorActivities.setScreenVisibility(visibility)
        if visibility != .available {
            let screenTask = activeScreenAnalysisTask
            let audioTask = visibility == .private ? activeAudioAnalysisTask : nil
            screenTask?.cancel()
            audioTask?.cancel()
            let audioConfiguration = audioConfigurationTask
            audioConfiguration?.cancel()
            audioConfigurationTask = nil
            audioConfigurationGeneration = nil
            await audioConfiguration?.value
            // Never let a previously available app/window become fallback metadata
            // after the active context turns private or unavailable.
            lastScreenContext = nil
            lastScreenJPEG = nil
            await screenCapture.invalidatePendingFramesAndWait()
            await systemAudioCapture.stop(flushPendingSegment: false)
            if visibility == .private {
                if isEnrollingVoice {
                    isEnrollingVoice = false
                    voiceEnrollmentMessage = "Voice enrollment was cancelled in a private context."
                }
                await audioCapture.stopAndDrain(
                    flushPendingSegment: false,
                    cancelCallbacks: true
                )
            }
            await screenTask?.value
            await audioTask?.value
            // If a newer transition resumed availability while an awaited
            // producer was stopping, that newer transition owns cleanup/restart.
            guard screenContextVisibility == visibility else { return }
            await screenBatcher.cancelAndDrain()
            if visibility == .private {
                await cancelPendingAudioTranscriptBatch()
            }
            let sourcesToDiscard: [ObservationSource] = visibility == .private
                ? [.screen, .ambientAudio, .meetingMicrophone, .meetingSystemAudio]
                : [.screen]
            try? await repository?.discardPendingAnalysisJobs(
                sources: sourcesToDiscard,
                processedAt: Date()
            )
            if let repository {
                pendingCount = (try? await repository.pendingAnalysisJobCount()) ?? pendingCount
            }
        }
        if previousVisibility == .private, visibility != .private, !isPreparingForTermination {
            configureAudio()
        }
        if visibility == .available,
           previousVisibility != .available,
           !settingsStore.settings.isPaused,
           !isPreparingForTermination,
           !isOpenAIWorkBlocked {
            await retryPending()
        }
        captureHealth = configuredCaptureHealth
    }

    func updateScreenCaptureFailure(_ message: String?) {
        guard screenCaptureFailureMessage != message else { return }
        screenCaptureFailureMessage = message
        captureHealth = configuredCaptureHealth
    }

    private func captureProcessingToken(for source: ObservationSource) -> UInt64? {
        source == .manualNote ? nil : capturePrivacyBoundary.token
    }

    private func captureCommitAuthorization(
        for source: ObservationSource
    ) -> CaptureCommitAuthorization? {
        switch source {
        case .screen:
            captureCommitFence.authorization(for: .screen)
        case .ambientAudio, .meetingMicrophone, .meetingSystemAudio:
            captureCommitFence.authorization(for: .audio)
        case .manualNote:
            nil
        }
    }

    private func isCaptureWorkValid(
        token: UInt64?,
        source: ObservationSource
    ) -> Bool {
        guard !Task.isCancelled, !settingsStore.settings.isPaused else { return false }
        if source != .manualNote, privacyCleanupTask != nil { return false }
        if let token, !capturePrivacyBoundary.accepts(token) { return false }
        return switch source {
        case .screen:
            screenContextVisibility == .available
        case .ambientAudio, .meetingMicrophone, .meetingSystemAudio:
            screenContextVisibility != .private
        case .manualNote:
            true
        }
    }

    private func requireCaptureWork(
        token: UInt64?,
        source: ObservationSource
    ) throws {
        guard isCaptureWorkValid(token: token, source: source) else {
            throw CancellationError()
        }
    }

    func processScreenFrame(_ frame: CapturedScreenFrame) async {
        let boundaryToken = capturePrivacyBoundary.token
        guard isCaptureWorkValid(token: boundaryToken, source: .screen) else { return }
        await transitionActiveScreenContext(to: frame.context)
        guard isCaptureWorkValid(token: boundaryToken, source: .screen) else { return }
        if settingsStore.settings.optimizationPhase == .legacy {
            await processLegacyScreenFrame(frame, boundaryToken: boundaryToken)
            return
        }
        await screenBatcher.submit(frame)
    }

    /// Meeting system audio follows context changes immediately rather than the
    /// 60-second maintenance timer. A closing meeting is flushed while its old
    /// context is still captured by the stream handler.
    private func transitionActiveScreenContext(to context: ActiveContext) async {
        let previousContext = lastScreenContext
        let wasMeeting = previousContext?.isMeeting == true
        let isMeeting = context.isMeeting
        let meetingContextChanged = wasMeeting
            && isMeeting
            && MeetingContextIdentity(previousContext) != MeetingContextIdentity(context)
        if wasMeeting, !isMeeting || meetingContextChanged {
            lastMeetingEndedAt = Date()
            // Both handlers still resolve against `previousContext` until these
            // flushes complete. Only then may the new meeting identity be stored.
            await systemAudioCapture.stop(flushPendingSegment: true)
            await audioCapture.flushPendingSegment()
            await audioTranscriptBatcher.flush()
            try? await repository?.expediteMeetingRefinementJobs(at: Date())
            await drainRefinementQueue()
        }
        lastScreenContext = context
        if isMeeting, !wasMeeting { lastMeetingEndedAt = nil }
        guard settingsStore.settings.meetingDetectionEnabled,
              settingsStore.settings.isAudioActiveNow,
              PermissionService.microphoneState() == .granted else {
            if isMeeting { await systemAudioCapture.stop(flushPendingSegment: false) }
            return
        }
        if isMeeting, !wasMeeting || meetingContextChanged {
            await startSystemAudio(for: context)
        }
    }

    private func startSystemAudio(for context: ActiveContext?) async {
        let settings = settingsStore.settings
        guard !Task.isCancelled,
              AudioCaptureAdmissionPolicy.allowsMeetingSystemAudio(
                isPreparingForTermination: isPreparingForTermination,
                isPaused: settings.isPaused,
                screenVisibility: screenContextVisibility,
                privacyCleanupInProgress: privacyCleanupTask != nil,
                isMeetingContext: context?.isMeeting == true && lastScreenContext?.isMeeting == true,
                meetingDetectionEnabled: settings.meetingDetectionEnabled,
                isAudioActiveNow: settings.isAudioActiveNow
              ) else { return }
        let audioBoundaryToken = capturePrivacyBoundary.token
        try? await systemAudioCapture.start { @Sendable wavData, duration in
            await AppState.shared.processSystemAudio(
                wavData,
                voicedDuration: duration,
                meetingContext: context,
                captureBoundaryToken: audioBoundaryToken
            )
        }
        let currentSettings = settingsStore.settings
        guard AudioCaptureAdmissionPolicy.allowsMeetingSystemAudio(
            isPreparingForTermination: isPreparingForTermination,
            isPaused: currentSettings.isPaused,
            screenVisibility: screenContextVisibility,
            privacyCleanupInProgress: privacyCleanupTask != nil,
            isMeetingContext: context?.isMeeting == true && lastScreenContext?.isMeeting == true,
            meetingDetectionEnabled: currentSettings.meetingDetectionEnabled,
            isAudioActiveNow: currentSettings.isAudioActiveNow
        ), capturePrivacyBoundary.accepts(audioBoundaryToken) else {
            await systemAudioCapture.stop(flushPendingSegment: false)
            return
        }
    }

    private func processLegacyScreenFrame(
        _ frame: CapturedScreenFrame,
        boundaryToken: UInt64
    ) async {
        guard isCaptureWorkValid(token: boundaryToken, source: .screen),
              let repository,
              let mediaStore else { return }
        let commitAuthorization = captureCommitAuthorization(for: .screen)
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
        var storedMediaIdentifier: String?
        var storedObservationID: UUID?
        do {
            async let recognized = ocr.recognizeText(in: frame.image)
            let expiresAt = frame.capturedAt.addingTimeInterval(
                TimeInterval(settingsStore.settings.mediaRetentionHours * 3_600)
            )
            let mediaID = try await mediaStore.store(
                frame.jpegData,
                fileExtension: "jpg",
                expiresAt: expiresAt
            )
            storedMediaIdentifier = mediaID
            let recognizedText = ExclusionPolicy.redactSensitiveText(try await recognized)
            guard isCaptureWorkValid(token: boundaryToken, source: .screen) else {
                try? await mediaStore.remove(identifier: mediaID)
                return
            }
            let observation = Observation(
                source: .screen,
                capturedAt: frame.capturedAt,
                expiresAt: expiresAt,
                applicationName: frame.context.applicationName,
                bundleIdentifier: frame.context.bundleIdentifier,
                windowTitle: frame.context.windowTitle,
                url: frame.context.url,
                text: recognizedText,
                mediaIdentifier: mediaID,
                contentFingerprint: frame.signature.digest,
                isMeeting: frame.context.isMeeting
            )
            try await repository.saveObservationWithoutAnalysisJob(observation)
            storedObservationID = observation.id
            guard isCaptureWorkValid(token: boundaryToken, source: .screen) else {
                try? await repository.deleteObservation(id: observation.id)
                try? await mediaStore.remove(identifier: mediaID)
                return
            }
            pendingCount += 1
            try await analyze(
                observation: observation,
                mediaData: frame.jpegData,
                captureBoundaryToken: boundaryToken,
                captureCommitAuthorization: commitAuthorization
            )
            try requireCaptureWork(token: boundaryToken, source: .screen)
        } catch {
            if !isCaptureWorkValid(token: boundaryToken, source: .screen) {
                if let storedObservationID {
                    try? await repository.deleteObservation(id: storedObservationID)
                }
                if let storedMediaIdentifier {
                    try? await mediaStore.remove(identifier: storedMediaIdentifier)
                }
                return
            }
            handleProcessingError(error, context: activityContext)
        }
        if !settingsStore.settings.isPaused, !hasPersistentIndicatorIssue {
            captureHealth = configuredCaptureHealth
        }
    }

    func processScreenBatch(_ batch: BatchedScreenObservation) async {
        let boundaryToken = capturePrivacyBoundary.token
        guard isCaptureWorkValid(token: boundaryToken, source: .screen),
              let repository,
              let mediaStore else { return }
        let activityContext: IndicatorActivityContext = batch.context.isMeeting ? .meeting : .screen
        let activityToken = indicatorActivities.beginLocal(
            IndicatorLocalActivityDescriptor(context: activityContext, startedAt: batch.capturedAt)
        )
        defer { indicatorActivities.finishLocal(activityToken) }
        indicatorActivities.setScreenVisibility(.available)
        if !hasPersistentIndicatorIssue {
            captureHealth = batch.context.isMeeting ? .meeting : configuredCaptureHealth
        }
        lastScreenJPEG = batch.jpegData
        var storedMediaIdentifier: String?
        var storedObservationID: UUID?
        do {
            let expiresAt = batch.capturedAt.addingTimeInterval(
                TimeInterval(settingsStore.settings.mediaRetentionHours * 3_600)
            )
            let mediaID = try await mediaStore.store(batch.jpegData, fileExtension: "jpg", expiresAt: expiresAt)
            storedMediaIdentifier = mediaID
            guard isCaptureWorkValid(token: boundaryToken, source: .screen) else {
                try? await mediaStore.remove(identifier: mediaID)
                return
            }
            let observation = Observation(
                source: .screen,
                capturedAt: batch.capturedAt,
                expiresAt: expiresAt,
                applicationName: batch.context.applicationName,
                bundleIdentifier: batch.context.bundleIdentifier,
                windowTitle: batch.context.windowTitle,
                url: batch.context.url,
                text: batch.text,
                mediaIdentifier: mediaID,
                contentFingerprint: batch.contentFingerprint,
                isMeeting: batch.context.isMeeting
            )
            try await repository.saveObservation(observation)
            storedObservationID = observation.id
            guard isCaptureWorkValid(token: boundaryToken, source: .screen) else {
                try? await repository.deleteObservation(id: observation.id)
                try? await mediaStore.remove(identifier: mediaID)
                return
            }
            pendingCount = try await repository.pendingAnalysisJobCount()
            await drainAnalysisQueue()
            try requireCaptureWork(token: boundaryToken, source: .screen)
        } catch {
            if !isCaptureWorkValid(token: boundaryToken, source: .screen) {
                if let storedObservationID {
                    try? await repository.deleteObservation(id: storedObservationID)
                }
                if let storedMediaIdentifier {
                    try? await mediaStore.remove(identifier: storedMediaIdentifier)
                }
                return
            }
            handleProcessingError(error, context: activityContext)
        }
        if !settingsStore.settings.isPaused, !hasPersistentIndicatorIssue {
            captureHealth = configuredCaptureHealth
        }
    }

    func processAudio(
        _ wavData: Data,
        voicedDuration: TimeInterval,
        captureBoundaryToken suppliedBoundaryToken: UInt64? = nil
    ) async {
        let boundaryToken = suppliedBoundaryToken ?? capturePrivacyBoundary.token
        guard voicedDuration > 0,
              !Task.isCancelled,
              capturePrivacyBoundary.accepts(boundaryToken),
              !settingsStore.settings.isPaused,
              screenContextVisibility != .private else { return }
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
        let context = lastScreenContext
        let source: ObservationSource = context?.isMeeting == true ? .meetingMicrophone : .ambientAudio
        guard isCaptureWorkValid(token: boundaryToken, source: source) else { return }
        guard let repository, let mediaStore else { return }
        let activityContext: IndicatorActivityContext = context?.isMeeting == true ? .meeting : .voice
        let activityToken = indicatorActivities.beginLocal(
            IndicatorLocalActivityDescriptor(context: activityContext)
        )
        defer { indicatorActivities.finishLocal(activityToken) }
        let now = Date()
        let expiresAt = now.addingTimeInterval(TimeInterval(settingsStore.settings.mediaRetentionHours * 3_600))
        var storedMediaIdentifier: String?
        var storedObservationID: UUID?
        do {
            let mediaID = try await mediaStore.store(wavData, fileExtension: "wav", expiresAt: expiresAt)
            storedMediaIdentifier = mediaID
            try requireCaptureWork(token: boundaryToken, source: source)
            let observation = Observation(
                source: source,
                capturedAt: now,
                expiresAt: expiresAt,
                applicationName: context?.applicationName,
                bundleIdentifier: context?.bundleIdentifier,
                windowTitle: context?.windowTitle,
                url: context?.url,
                mediaIdentifier: mediaID,
                isMeeting: context?.isMeeting ?? false
            )
            try await repository.saveObservation(observation)
            storedObservationID = observation.id
            try requireCaptureWork(token: boundaryToken, source: source)
            pendingCount = try await repository.pendingAnalysisJobCount()
            await drainAnalysisQueue()
            pendingCount = try await repository.pendingAnalysisJobCount()
        } catch {
            if !isCaptureWorkValid(token: boundaryToken, source: source) {
                if let storedObservationID {
                    try? await repository.deleteObservation(id: storedObservationID)
                }
                if let storedMediaIdentifier {
                    try? await mediaStore.remove(identifier: storedMediaIdentifier)
                }
                return
            }
            handleProcessingError(error, context: activityContext)
        }
        if !settingsStore.settings.isPaused, !hasPersistentIndicatorIssue {
            captureHealth = configuredCaptureHealth
        }
    }

    func processSystemAudio(
        _ wavData: Data,
        voicedDuration: TimeInterval,
        meetingContext: ActiveContext? = nil,
        captureBoundaryToken suppliedBoundaryToken: UInt64? = nil
    ) async {
        let source: ObservationSource = .meetingSystemAudio
        let boundaryToken = suppliedBoundaryToken ?? capturePrivacyBoundary.token
        guard voicedDuration > 0,
              !Task.isCancelled,
              isCaptureWorkValid(token: boundaryToken, source: source),
              let repository,
              let mediaStore else { return }
        let activityToken = indicatorActivities.beginLocal(
            IndicatorLocalActivityDescriptor(context: .meeting)
        )
        defer { indicatorActivities.finishLocal(activityToken) }
        let now = Date()
        let expiresAt = now.addingTimeInterval(TimeInterval(settingsStore.settings.mediaRetentionHours * 3_600))
        var storedMediaIdentifier: String?
        var storedObservationID: UUID?
        do {
            let mediaID = try await mediaStore.store(wavData, fileExtension: "wav", expiresAt: expiresAt)
            storedMediaIdentifier = mediaID
            try requireCaptureWork(token: boundaryToken, source: source)
            let observation = Observation(
                source: .meetingSystemAudio,
                capturedAt: now,
                expiresAt: expiresAt,
                applicationName: meetingContext?.applicationName ?? lastScreenContext?.applicationName,
                bundleIdentifier: meetingContext?.bundleIdentifier ?? lastScreenContext?.bundleIdentifier,
                windowTitle: meetingContext?.windowTitle ?? lastScreenContext?.windowTitle,
                url: meetingContext?.url ?? lastScreenContext?.url,
                mediaIdentifier: mediaID,
                isMeeting: true
            )
            try await repository.saveObservation(observation)
            storedObservationID = observation.id
            try requireCaptureWork(token: boundaryToken, source: source)
            pendingCount = try await repository.pendingAnalysisJobCount()
            await drainAnalysisQueue()
            pendingCount = try await repository.pendingAnalysisJobCount()
        } catch {
            if !isCaptureWorkValid(token: boundaryToken, source: source) {
                if let storedObservationID {
                    try? await repository.deleteObservation(id: storedObservationID)
                }
                if let storedMediaIdentifier {
                    try? await mediaStore.remove(identifier: storedMediaIdentifier)
                }
                return
            }
            handleProcessingError(error, context: .meeting)
        }
        if !settingsStore.settings.isPaused, !hasPersistentIndicatorIssue {
            captureHealth = configuredCaptureHealth
        }
    }

    @discardableResult
    private func submitAudioTranscript(
        _ observation: Observation,
        audioDuration: TimeInterval
    ) async -> AudioTranscriptSubmissionDisposition {
        let context = ActiveContext(
            applicationName: observation.applicationName ?? (observation.isMeeting ? "Meeting" : "Ambient audio"),
            bundleIdentifier: observation.bundleIdentifier,
            windowTitle: observation.windowTitle,
            url: observation.url,
            isMeeting: observation.isMeeting
        )
        let disposition = await audioTranscriptBatcher.submit(AudioTranscriptInput(
            observationID: observation.id,
            source: observation.source,
            capturedAt: observation.capturedAt,
            context: context,
            text: observation.text,
            audioDuration: audioDuration
        ))
        switch disposition {
        case .accepted:
            await optimizationRecorder.record(OptimizationTelemetryRecord(
                metric: .batchFrameAccepted,
                source: OptimizationTelemetrySource(observation.source),
                isMeeting: observation.isMeeting
            ))
        case .deduplicated:
            await optimizationRecorder.record(OptimizationTelemetryRecord(
                metric: .batchSuppressedDuplicate,
                reason: .duplicateTranscript,
                source: OptimizationTelemetrySource(observation.source),
                isMeeting: observation.isMeeting
            ))
        case .cancelled, .ignoredEmpty, .ignoredUnsupportedSource:
            break
        }
        return disposition
    }

    func processAudioTranscriptBatch(_ batch: BatchedAudioTranscript) async {
        guard !Task.isCancelled else { return }
        let boundarySource: ObservationSource = batch.context.isMeeting ? .meetingMicrophone : .ambientAudio
        let boundaryToken = capturePrivacyBoundary.token
        guard let repository else { return }
        guard isCaptureWorkValid(token: boundaryToken, source: boundarySource) else {
            try? await repository.discardAnalysisJobs(
                observationIDs: batch.observationIDs,
                processedAt: Date()
            )
            return
        }
        guard !batch.text.isEmpty else { return }
        let telemetrySource = batch.sources.count == 1
            ? batch.sources.first.map(OptimizationTelemetrySource.init)
            : .unknown
        await optimizationRecorder.record(OptimizationTelemetryRecord(
            metric: .batchEmitted,
            source: telemetrySource,
            occurrenceCount: batch.observationIDs.count,
            isMeeting: batch.context.isMeeting
        ))
        var storedBatchObservationID: UUID?
        do {
            var representative: Observation?
            for identifier in batch.contributingObservationIDs where representative == nil {
                representative = try await repository.observation(id: identifier)
            }
            try requireCaptureWork(token: boundaryToken, source: boundarySource)
            let source = representative?.source
                ?? (batch.context.isMeeting ? .meetingMicrophone : .ambientAudio)
            let expiresAt = batch.capturedAt.addingTimeInterval(
                TimeInterval(settingsStore.settings.mediaRetentionHours * 3_600)
            )
            let fingerprint = "audio-batch:" + batch.observationIDs
                .map(\.uuidString)
                .sorted()
                .joined(separator: ":")
            let observation = Observation(
                source: source,
                capturedAt: batch.startedAt,
                expiresAt: expiresAt,
                applicationName: batch.context.applicationName,
                bundleIdentifier: batch.context.bundleIdentifier,
                windowTitle: batch.context.windowTitle,
                url: batch.context.url,
                text: ExclusionPolicy.redactSensitiveText(batch.text),
                mediaIdentifier: representative?.mediaIdentifier,
                contentFingerprint: fingerprint,
                isMeeting: batch.context.isMeeting
            )
            try await repository.saveAudioTranscriptBatchObservation(
                observation,
                consuming: batch.observationIDs,
                processedAt: Date()
            )
            storedBatchObservationID = observation.id
            try requireCaptureWork(token: boundaryToken, source: boundarySource)
            pendingCount = try await repository.pendingAnalysisJobCount()
            await drainAnalysisQueue()
        } catch {
            if !isCaptureWorkValid(token: boundaryToken, source: boundarySource) {
                try? await repository.discardAnalysisJobs(
                    observationIDs: batch.observationIDs + [storedBatchObservationID].compactMap { $0 },
                    processedAt: Date()
                )
                if let storedBatchObservationID {
                    try? await repository.deleteObservation(id: storedBatchObservationID)
                }
                return
            }
            handleProcessingError(error, context: batch.context.isMeeting ? .meeting : .voice)
        }
    }

    private func cancelPendingAudioTranscriptBatch() async {
        let observationIDs = await audioTranscriptBatcher.cancelAndDrain()
        guard !observationIDs.isEmpty, let repository else { return }
        do {
            try await repository.discardAnalysisJobs(
                observationIDs: observationIDs,
                processedAt: Date()
            )
        } catch {
            handleProcessingError(error, context: .voice)
        }
    }

    func retryPending() async {
        await drainAnalysisQueue()
        await drainRefinementQueue()
    }

    func resumeCredentialBlockedJobs() async {
        let persistenceTasks = Array(openAIBlockPersistenceTasks.values)
        persistenceTasks.forEach { $0.cancel() }
        for task in persistenceTasks { await task.value }
        openAIBlockPersistenceTasks.removeAll()
        pendingOpenAIBlockPersistence.removeAll()
        do {
            if let repository {
                try await repository.unblockCredentialAnalysisJobs(at: Date())
                try await repository.unblockCredentialRefinementJobs(at: Date())
                try await repository.clearOpenAIWorkBlock(at: Date())
            }
            isOpenAIWorkBlocked = false
            captureHealth = configuredCaptureHealth
            await retryPending()
        } catch {
            handleProcessingError(error, context: .credentials)
        }
    }

    func refreshLocalIntelligenceStatus(prewarm: Bool = false) async {
        let languageTag = settingsStore.settings.outputLanguageTag
        let mode = OptimizationRuntimePolicy.localGateMode
        if prewarm {
            await localGate.prewarm(languageTag: languageTag, mode: mode)
        }
        localIntelligenceStatus = await localGate.status(languageTag: languageTag, mode: mode)
    }

    private enum AnalysisWorkerKind: Equatable {
        case screen
        case audio

        var sources: [ObservationSource] {
            switch self {
            case .screen: [.screen, .manualNote]
            case .audio: [.ambientAudio, .meetingMicrophone, .meetingSystemAudio]
            }
        }

        func claimSources(screenVisibility: ScreenContextVisibility) -> [ObservationSource] {
            switch self {
            case .screen:
                // Manual notes are explicit user input and remain processable
                // while screen capture is private or unavailable. Screen jobs
                // stay durable until visibility becomes available again.
                screenVisibility == .available ? sources : [.manualNote]
            case .audio:
                sources
            }
        }
    }

    private func drainAnalysisQueue() async {
        guard !isPreparingForTermination,
              !isOpenAIWorkBlocked,
              !settingsStore.settings.isPaused else { return }
        screenAnalysisDrainRequested = true
        audioAnalysisDrainRequested = true
        // Each source owns an independent worker. A long transcription can no
        // longer hold up a critical screen observation.
        if activeScreenAnalysisTask == nil {
            activeScreenAnalysisTask = Task<Void, Never> { @MainActor [weak self] in
                guard let self else { return }
                await self.drainAnalysisWorker(.screen)
                self.activeScreenAnalysisTask = nil
                if self.shouldRestartAnalysisWorker(.screen) {
                    await self.drainAnalysisQueue()
                }
            }
        }
        if activeAudioAnalysisTask == nil {
            activeAudioAnalysisTask = Task<Void, Never> { @MainActor [weak self] in
                guard let self else { return }
                await self.drainAnalysisWorker(.audio)
                self.activeAudioAnalysisTask = nil
                if self.shouldRestartAnalysisWorker(.audio) {
                    await self.drainAnalysisQueue()
                }
            }
        }
        if let repository {
            pendingCount = (try? await repository.pendingAnalysisJobCount()) ?? pendingCount
        }
    }

    private func drainAnalysisWorker(_ worker: AnalysisWorkerKind) async {
        let isAlreadyRunning = switch worker {
        case .screen: isDrainingScreenAnalysisQueue
        case .audio: isDrainingAudioAnalysisQueue
        }
        guard !isAlreadyRunning,
              !isOpenAIWorkBlocked,
              !isPreparingForTermination,
              !settingsStore.settings.isPaused,
              worker != .audio || screenContextVisibility != .private,
              let repository,
              let mediaStore else { return }
        switch worker {
        case .screen: isDrainingScreenAnalysisQueue = true
        case .audio: isDrainingAudioAnalysisQueue = true
        }
        defer {
            switch worker {
            case .screen:
                isDrainingScreenAnalysisQueue = false
            case .audio:
                isDrainingAudioAnalysisQueue = false
            }
        }

        do {
            while !Task.isCancelled,
                  !isOpenAIWorkBlocked,
                  !isPreparingForTermination,
                  !settingsStore.settings.isPaused,
                  worker != .audio || screenContextVisibility != .private {
                switch worker {
                case .screen: screenAnalysisDrainRequested = false
                case .audio: audioAnalysisDrainRequested = false
                }
                let claimedBoundaryToken = capturePrivacyBoundary.token
                let claimedCommitAuthorization = captureCommitFence.authorization(
                    for: worker == .screen ? .screen : .audio
                )
                let jobs = try await repository.claimAnalysisJobs(
                    limit: 1,
                    now: Date(),
                    leaseDuration: 10 * 60,
                    sources: worker.claimSources(screenVisibility: screenContextVisibility)
                )
                guard let job = jobs.first else {
                    let wakeRequested = switch worker {
                    case .screen: screenAnalysisDrainRequested
                    case .audio: audioAnalysisDrainRequested
                    }
                    if wakeRequested { continue }
                    break
                }
                    guard var observation = try await repository.observation(id: job.observationID),
                          observation.expiresAt > Date() else {
                        try await repository.completeAnalysisJob(id: job.id)
                        continue
                    }
                    let jobBoundaryToken: UInt64? = observation.source == .manualNote
                        ? nil
                        : claimedBoundaryToken
                    let jobCommitAuthorization: CaptureCommitAuthorization? = observation.source == .manualNote
                        ? nil
                        : claimedCommitAuthorization
                    var media: Data?
                    if let identifier = observation.mediaIdentifier {
                        media = try? await mediaStore.read(identifier: identifier)
                    }
                    guard !isOpenAIWorkBlocked,
                          isCaptureWorkValid(token: jobBoundaryToken, source: observation.source) else {
                        try await repository.rescheduleAnalysisJob(
                            id: job.id,
                            state: .retryable,
                            nextAttemptAt: Date(),
                            errorKind: .cancelled,
                            errorMessage: "Processing paused at a privacy boundary."
                        )
                        break
                    }
                    do {
                        if observation.source != .screen, observation.text.isEmpty, let media {
                            observation.text = ExclusionPolicy.redactSensitiveText(
                                try await OpenAIDurableAttemptContext.$number.withValue(
                                    OpenAIDurableAttemptContext.base(forDurableAttempt: job.attempts)
                                ) {
                                    try await self.transcribeAudioObservation(observation, wavData: media)
                                }
                            )
                            try requireCaptureWork(token: jobBoundaryToken, source: observation.source)
                            try await repository.saveObservation(observation)
                            try requireCaptureWork(token: jobBoundaryToken, source: observation.source)
                        }
                        let isRawAudioSegment = switch observation.source {
                        case .ambientAudio, .meetingMicrophone, .meetingSystemAudio:
                            observation.contentFingerprint?.hasPrefix("audio-batch:") != true
                        case .screen, .manualNote:
                            false
                        }
                        if isRawAudioSegment {
                            if settingsStore.settings.optimizationPhase == .legacy {
                                try await OpenAIDurableAttemptContext.$number.withValue(
                                    OpenAIDurableAttemptContext.base(forDurableAttempt: job.attempts)
                                ) {
                                    try await self.analyze(
                                        observation: observation,
                                        mediaData: nil,
                                        isRetry: job.attempts > 1,
                                        captureBoundaryToken: jobBoundaryToken,
                                        captureCommitAuthorization: jobCommitAuthorization
                                    )
                                }
                                try requireCaptureWork(token: jobBoundaryToken, source: observation.source)
                                try await repository.completeAnalysisJob(id: job.id)
                                continue
                            }
                            let disposition = await submitAudioTranscript(observation, audioDuration: 0)
                            try requireCaptureWork(token: jobBoundaryToken, source: observation.source)
                            switch disposition {
                            case .accepted, .deduplicated:
                                // The raw job remains leased until the batch is
                                // materialized transactionally. A crash can then
                                // reclaim the transcript without retranscribing it.
                                break
                            case .cancelled:
                                try await repository.rescheduleAnalysisJob(
                                    id: job.id,
                                    state: .retryable,
                                    nextAttemptAt: Date(),
                                    errorKind: .cancelled,
                                    errorMessage: "Processing paused at a privacy boundary."
                                )
                            case .ignoredEmpty, .ignoredUnsupportedSource:
                                try await repository.markObservationProcessed(id: observation.id, at: Date())
                            }
                            continue
                        }
                        try await OpenAIDurableAttemptContext.$number.withValue(
                            OpenAIDurableAttemptContext.base(forDurableAttempt: job.attempts)
                        ) {
                            try await self.analyze(
                                observation: observation,
                                mediaData: observation.source == .screen ? media : nil,
                                isRetry: job.attempts > 1,
                                captureBoundaryToken: jobBoundaryToken,
                                captureCommitAuthorization: jobCommitAuthorization
                            )
                        }
                        try requireCaptureWork(token: jobBoundaryToken, source: observation.source)
                        try await repository.completeAnalysisJob(id: job.id)
                    } catch {
                        let crossedBoundary = jobBoundaryToken.map {
                            !capturePrivacyBoundary.accepts($0)
                        } ?? false
                        if crossedBoundary {
                            try await repository.discardAnalysisJobs(
                                observationIDs: [observation.id],
                                processedAt: Date()
                            )
                            if let identifier = observation.mediaIdentifier {
                                try? await mediaStore.remove(identifier: identifier)
                            }
                        } else {
                            try await rescheduleAnalysis(job: job, after: error)
                        }
                        handleProcessingError(error, context: Self.indicatorContext(for: observation))
                    }
            }
        } catch {
            handleProcessingError(error, context: .followUp)
        }
        pendingCount = (try? await repository.pendingAnalysisJobCount()) ?? pendingCount
        await drainRefinementQueue()
    }

    private func shouldRestartAnalysisWorker(_ worker: AnalysisWorkerKind) -> Bool {
        let requested = switch worker {
        case .screen: screenAnalysisDrainRequested
        case .audio: audioAnalysisDrainRequested
        }
        return requested
            && !isOpenAIWorkBlocked
            && !isPreparingForTermination
            && !settingsStore.settings.isPaused
            && repository != nil
            && mediaStore != nil
            && (worker != .audio || screenContextVisibility != .private)
    }

    private func transcribeAudioObservation(
        _ observation: Observation,
        wavData: Data
    ) async throws -> String {
        if !observation.isMeeting {
            let selectedLanguage = settingsStore.settings.outputLanguageTag
            let localLanguage = selectedLanguage == "auto" ? Locale.current.identifier : selectedLanguage
            let attempt = await localSpeechAnalyzer.transcribe(
                wavData: wavData,
                languageTag: localLanguage,
                isMeeting: false
            )
            if case .completed(let transcript) = attempt {
                return transcript.text
            }
        }

        guard !isOpenAIWorkBlocked else {
            throw OpenAIClientError.missingAPIKey
        }
        guard let key = try settingsStore.apiKey() else {
            throw OpenAIClientError.missingAPIKey
        }
        return try await ai.transcribe(
            wavData: wavData,
            diarize: observation.isMeeting,
            languageTag: settingsStore.settings.outputLanguageTag,
            knownSpeakerReference: observation.isMeeting ? try settingsStore.voiceReference() : nil,
            apiKey: key
        )
    }

    private func drainRefinementQueue() async {
        guard !isPreparingForTermination,
              !isOpenAIWorkBlocked,
              !settingsStore.settings.isPaused else { return }
        refinementDrainRequested = true
        guard activeRefinementTask == nil else { return }
        activeRefinementTask = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.drainRefinementWorker()
            self.activeRefinementTask = nil
            if self.shouldRestartRefinementWorker {
                await self.drainRefinementQueue()
            }
        }
    }

    private func drainRefinementWorker() async {
        guard !isDrainingRefinementQueue,
              !isPreparingForTermination,
              !isOpenAIWorkBlocked,
              !settingsStore.settings.isPaused,
              OptimizationRuntimePolicy.deferredTerraRefinementEnabled,
              let repository,
              let key = try? settingsStore.apiKey() else { return }
        isDrainingRefinementQueue = true
        defer {
            isDrainingRefinementQueue = false
        }

        do {
            var didUpdateEvent = false
            while !Task.isCancelled,
                  !isPreparingForTermination,
                  !isOpenAIWorkBlocked,
                  !settingsStore.settings.isPaused {
                refinementDrainRequested = false
                let jobs = try await repository.claimRefinementJobs(
                    limit: 1,
                    now: Date(),
                    leaseDuration: 20 * 60,
                    criticalLeaseDuration: 10 * 60
                )
                guard let job = jobs.first else {
                    if refinementDrainRequested { continue }
                    break
                }
                guard let event = try await repository.event(id: job.eventID) else {
                    await optimizationRecorder.record(OptimizationTelemetryRecord(
                        metric: .refinementDiscardedStale,
                        reason: .staleRevision
                    ))
                    try await repository.completeRefinementJob(
                        id: job.id,
                        eventRevision: job.eventRevision
                    )
                    continue
                }
                guard abs(event.updatedAt.timeIntervalSince(job.eventRevision)) < 0.001 else {
                    // The event was edited or consolidated after this job was queued.
                    await optimizationRecorder.record(OptimizationTelemetryRecord(
                        metric: .refinementDiscardedStale,
                        reason: .staleRevision,
                        isMeeting: event.kind == .meeting
                    ))
                    try await repository.completeRefinementJob(
                        id: job.id,
                        eventRevision: job.eventRevision
                    )
                    continue
                }
                await optimizationRecorder.record(OptimizationTelemetryRecord(
                    metric: .refinementQueueWait,
                    source: .unknown,
                    latencyMilliseconds: Int(max(0, Date().timeIntervalSince(job.createdAt)) * 1_000),
                    isMeeting: event.kind == .meeting
                ))
                do {
                    let refined = try await OpenAIDurableAttemptContext.$number.withValue(
                        OpenAIDurableAttemptContext.base(forDurableAttempt: job.attempts)
                    ) {
                        try await self.ai.refine(
                            event: event,
                            outputLanguage: self.settingsStore.outputLanguagePrompt(),
                            serviceTier: job.isCritical ? .default : .flex,
                            apiKey: key
                        )
                    }
                    let applied = try await repository.applyRefinementResult(
                        refined,
                        expectedRevision: job.eventRevision,
                        jobID: job.id
                    )
                    guard applied else {
                        await optimizationRecorder.record(OptimizationTelemetryRecord(
                            metric: .refinementDiscardedStale,
                            reason: .staleRevision,
                            isMeeting: event.kind == .meeting
                        ))
                        continue
                    }
                    await optimizationRecorder.record(OptimizationTelemetryRecord(
                        metric: .refinementCompleted,
                        source: .unknown,
                        latencyMilliseconds: Int(max(0, Date().timeIntervalSince(job.createdAt)) * 1_000),
                        isMeeting: event.kind == .meeting
                    ))
                    didUpdateEvent = true
                } catch {
                    try await rescheduleRefinement(job: job, after: error)
                    handleProcessingError(error, context: event.kind == .meeting ? .meeting : .screen)
                }
            }
            if didUpdateEvent { await refresh() }
        } catch {
            handleProcessingError(error, context: .screen)
        }
    }

    private var shouldRestartRefinementWorker: Bool {
        refinementDrainRequested
            && !isPreparingForTermination
            && !isOpenAIWorkBlocked
            && !settingsStore.settings.isPaused
            && OptimizationRuntimePolicy.deferredTerraRefinementEnabled
            && repository != nil
            && (try? settingsStore.apiKey()) != nil
    }

    private func rescheduleAnalysis(job: AnalysisJob, after error: Error) async throws {
        guard let repository else { return }
        let disposition = Self.retryDisposition(for: error, attempts: job.attempts, isFlex: false)
        if disposition.state == .blockedCredentials {
            isOpenAIWorkBlocked = true
            let message = Self.openAIBlockedMessage(for: error)
            persistOpenAIBlock(
                errorKind: disposition.kind,
                errorMessage: message,
                occurredAt: Date()
            )
            settingsStore.setAPIKeyState(.invalid(message))
            captureHealth = .error("OpenAI credentials or spending limit need attention.")
            return
        }
        try await repository.rescheduleAnalysisJob(
            id: job.id,
            state: disposition.state,
            nextAttemptAt: disposition.nextAttemptAt,
            errorKind: disposition.kind,
            errorMessage: String(error.localizedDescription.prefix(500))
        )
    }

    private func rescheduleRefinement(job: RefinementJob, after error: Error) async throws {
        guard let repository else { return }
        let disposition = Self.retryDisposition(for: error, attempts: job.attempts, isFlex: !job.isCritical)
        if disposition.state == .blockedCredentials {
            isOpenAIWorkBlocked = true
            let message = Self.openAIBlockedMessage(for: error)
            persistOpenAIBlock(
                errorKind: disposition.kind,
                errorMessage: message,
                occurredAt: Date()
            )
            settingsStore.setAPIKeyState(.invalid(message))
            captureHealth = .error("OpenAI credentials or spending limit need attention.")
            return
        }
        try await repository.rescheduleRefinementJob(
            id: job.id,
            eventRevision: job.eventRevision,
            state: disposition.state,
            nextAttemptAt: disposition.nextAttemptAt,
            errorKind: disposition.kind,
            errorMessage: String(error.localizedDescription.prefix(500))
        )
        if !job.isCritical, disposition.state == .terminal {
            await optimizationRecorder.record(OptimizationTelemetryRecord(
                metric: .refinementAbandonedFlex,
                reason: .flexUnavailable
            ))
        }
    }

    nonisolated static func retryDisposition(
        for error: Error,
        attempts: Int,
        isFlex: Bool
    ) -> (state: AnalysisJobState, nextAttemptAt: Date, kind: AnalysisErrorKind) {
        let now = Date()
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return (.retryable, now, .cancelled)
        }
        if let urlError = error as? URLError {
            let retry = attempts < AnalysisRetryPolicy.maximumTransientAttempts
            return (
                retry ? .retryable : .terminal,
                now.addingTimeInterval(AnalysisRetryPolicy.delay(afterAttempt: attempts)),
                urlError.code == .timedOut ? .timeout : .network
            )
        }
        guard let clientError = error as? OpenAIClientError else {
            let retry = attempts < AnalysisRetryPolicy.maximumTransientAttempts
            return (
                retry ? .retryable : .terminal,
                now.addingTimeInterval(AnalysisRetryPolicy.delay(afterAttempt: attempts)),
                .unknown
            )
        }
        switch clientError {
        case .missingAPIKey:
            return (.blockedCredentials, .distantFuture, .credentials)
        case .invalidResponse, .malformedStructuredOutput:
            return (.terminal, now, .invalidResponse)
        case .requestFailed(let failure):
            let blockedKinds: Set<String> = [
                "credit_balance_exhausted",
                "organization_spend_limit_exceeded",
                "project_spend_limit_exceeded",
                "organization_usage_limit_exceeded",
                "insufficient_quota"
            ]
            if failure.status == 401 || failure.status == 403 || blockedKinds.contains(failure.errorKind) {
                return (.blockedCredentials, .distantFuture, .credentials)
            }
            if isFlex, failure.errorKind == "resource_unavailable" {
                let retry = attempts < AnalysisRetryPolicy.maximumFlexAttempts
                return (
                    retry ? .retryable : .terminal,
                    now.addingTimeInterval(AnalysisRetryPolicy.delay(
                        afterAttempt: attempts,
                        retryAfter: failure.retryAfterSeconds
                    )),
                    .rateLimited
                )
            }
            if failure.status == 429 {
                let retry = attempts < AnalysisRetryPolicy.maximumRateLimitAttempts
                return (
                    retry ? .retryable : .terminal,
                    now.addingTimeInterval(AnalysisRetryPolicy.delay(
                        afterAttempt: attempts,
                        retryAfter: failure.retryAfterSeconds
                    )),
                    .rateLimited
                )
            }
            if failure.status == 408 || (500..<600).contains(failure.status) {
                let retry = attempts < AnalysisRetryPolicy.maximumTransientAttempts
                return (
                    retry ? .retryable : .terminal,
                    now.addingTimeInterval(AnalysisRetryPolicy.delay(afterAttempt: attempts)),
                    failure.status == 408 ? .timeout : .server
                )
            }
            return (.terminal, now, .terminalRequest)
        }
    }

    private nonisolated static func openAIBlockedMessage(for error: Error) -> String {
        guard let clientError = error as? OpenAIClientError,
              case .requestFailed(let failure) = clientError else {
            return "OpenAI API access is blocked. Save and validate the key after correcting it."
        }
        let isSpendLimit = [
            "credit_balance_exhausted",
            "organization_spend_limit_exceeded",
            "project_spend_limit_exceeded",
            "organization_usage_limit_exceeded",
            "insufficient_quota"
        ].contains(failure.errorKind)
        return isSpendLimit
            ? "OpenAI spending limit reached. Correct the project budget, then validate the API key to resume."
            : clientError.localizedDescription
    }

    private nonisolated static let restoredOpenAIBlockMessage =
        "OpenAI access is paused after a key or spending-limit failure. Validate the API key to resume."

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
        guard AudioCaptureAdmissionPolicy.allowsCapture(
            isPreparingForTermination: isPreparingForTermination,
            isPaused: settingsStore.settings.isPaused,
            screenVisibility: screenContextVisibility,
            privacyCleanupInProgress: privacyCleanupTask != nil
        ) else {
            voiceEnrollmentMessage = "Voice enrollment is unavailable while Iriz is paused or the current context is private."
            return
        }
        guard await PermissionService.requestMicrophone() else {
            voiceEnrollmentMessage = "Microphone permission is required."
            return
        }
        guard AudioCaptureAdmissionPolicy.allowsCapture(
            isPreparingForTermination: isPreparingForTermination,
            isPaused: settingsStore.settings.isPaused,
            screenVisibility: screenContextVisibility,
            privacyCleanupInProgress: privacyCleanupTask != nil
        ) else {
            voiceEnrollmentMessage = "Voice enrollment is unavailable while Iriz is paused or the current context is private."
            return
        }
        let audioBoundaryToken = capturePrivacyBoundary.token
        isEnrollingVoice = true
        voiceEnrollmentMessage = "Speak naturally for 2–10 seconds, then pause."
        do {
            try audioCapture.start { @Sendable wavData, duration in
                await AppState.shared.processAudio(
                    wavData,
                    voicedDuration: duration,
                    captureBoundaryToken: audioBoundaryToken
                )
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
        guard !isPreparingForTermination,
              !trimmed.isEmpty,
              !isAsking,
              let searchService,
              let repository else { return }
        beginTrackedInteractiveWorkflow()
        defer { finishTrackedInteractiveWorkflow() }

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
            if let key = try settingsStore.apiKey(), !isOpenAIWorkBlocked {
                answer = try await ai.answer(
                    question: trimmed,
                    candidates: candidates,
                    conversationContext: Array(previousAnswers.suffix(4)),
                    outputLanguage: settingsStore.outputLanguagePrompt(),
                    apiKey: key
                )
            } else if isOpenAIWorkBlocked {
                answer = AssistantAnswer(
                    question: trimmed,
                    text: "OpenAI fallback is paused until the API key or project spending limit is corrected and validated in Settings.",
                    citations: []
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
        guard !isPreparingForTermination, let repository else { return }
        beginTrackedInteractiveWorkflow()
        defer { finishTrackedInteractiveWorkflow() }
        pendingFollowUpMergeConfirmation = nil
        let selection = FollowUpMergeResolver.activeSelection(ids: ids, from: commitments)
        let values = selection.commitments
        guard values.count >= 2 else { return }
        let participatingIDs = selection.sourceIDs
        guard preparedDraft != nil || !isOpenAIWorkBlocked else {
            followUpOperationMessage = "OpenAI is paused. Correct and validate the API key or project budget before merging Actions."
            return
        }
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
            handleProcessingError(error, context: .followUp)
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

    private func beginTrackedInteractiveWorkflow() {
        activeInteractiveWorkflowCount += 1
    }

    private func finishTrackedInteractiveWorkflow() {
        activeInteractiveWorkflowCount = max(0, activeInteractiveWorkflowCount - 1)
        if activeInteractiveWorkflowCount == 0 {
            let waiters = interactiveWorkflowWaiters
            interactiveWorkflowWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    private func waitForInteractiveWorkflows() async {
        guard activeInteractiveWorkflowCount > 0 else { return }
        await withCheckedContinuation { continuation in
            interactiveWorkflowWaiters.append(continuation)
        }
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
        guard !isPreparingForTermination else { return }
        beginTrackedInteractiveWorkflow()
        defer { finishTrackedInteractiveWorkflow() }
        settingsStore.setAPIKeyState(.testing)
        do {
            try await ai.validateAPIKey(candidate)
            try settingsStore.saveAPIKey(candidate)
            settingsStore.setAPIKeyState(.valid)
            if secureStorageState == .ready {
                captureHealth = configuredCaptureHealth
            }
            await resumeCredentialBlockedJobs()
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

    /// Quiesces local producers and durably flushes the tail of both telemetry
    /// streams before AppKit allows the process to exit.
    func prepareForTermination() async -> Bool {
        if !hasQuiescedForTermination {
            guard !isPreparingForTermination else { return false }
            isPreparingForTermination = true
            let bootstrap = bootstrapTask
            bootstrap?.cancel()
            await bootstrap?.value
            bootstrapTask = nil
            let maintenance = maintenanceTask
            let audioConfiguration = audioConfigurationTask
            let privacyCleanup = privacyCleanupTask
            maintenance?.cancel()
            audioConfiguration?.cancel()
            maintenanceTask = nil
            audioConfigurationTask = nil
            audioConfigurationGeneration = nil
            await maintenance?.value
            await audioConfiguration?.value
            await privacyCleanup?.value
            privacyCleanupTask = nil

            // Unlike privacy/pause cancellation, app termination preserves every
            // already-authorized audio tail as a durable local observation. Cloud
            // workers remain gated by `isPreparingForTermination`.
            await audioCapture.stopAndDrain(flushPendingSegment: true, cancelCallbacks: false)
            await systemAudioCapture.stop(flushPendingSegment: true)
            await screenCapture.stop()
            // No analysis worker may append a transcript after the final batch
            // drain. Stop and await cloud work before materializing batch tails.
            let screenTask = activeScreenAnalysisTask
            let audioTask = activeAudioAnalysisTask
            let refinementTask = activeRefinementTask
            screenTask?.cancel()
            audioTask?.cancel()
            refinementTask?.cancel()
            await screenTask?.value
            await audioTask?.value
            await refinementTask?.value
            // Materialize already-produced OCR/transcripts into the encrypted durable
            // queues, but do not start new cloud work while the process is exiting.
            await screenBatcher.flush()
            await audioTranscriptBatcher.flush()
            await screenBatcher.drainEmissions()
            await audioTranscriptBatcher.drainEmissions()
            await screenBatcher.cancelAndDrain()
            _ = await audioTranscriptBatcher.cancelAndDrain()
            await waitForInteractiveWorkflows()
            hasQuiescedForTermination = true
        }

        var canTerminate = await waitForOpenAIBlockPersistence()
        if !canTerminate {
            storageError = "Iriz is keeping the app open because the OpenAI safety block is not yet durable. Try quitting again after storage recovers."
        }
        do {
            try await usageRecorder.flushDurably()
        } catch {
            canTerminate = false
            storageError = "OpenAI usage tail could not be persisted: \(error.localizedDescription)"
        }
        do {
            try await optimizationRecorder.flushDurably()
        } catch {
            canTerminate = false
            storageError = "Optimization telemetry tail could not be persisted: \(error.localizedDescription)"
        }
        return canTerminate
    }

    func updateDailyDigestSchedule() {
        let hour = settingsStore.settings.dailyDigestHour
        let enabled = settingsStore.settings.dailyDigestEnabled
        Task {
            await notifications.configureDailyDigest(hour: hour, enabled: enabled)
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

    private func analyze(
        observation: Observation,
        mediaData: Data?,
        isRetry: Bool = false,
        captureBoundaryToken: UInt64? = nil,
        captureCommitAuthorization suppliedCommitAuthorization: CaptureCommitAuthorization? = nil
    ) async throws {
        guard let repository else { return }
        try requireCaptureWork(token: captureBoundaryToken, source: observation.source)
        let commitAuthorization = suppliedCommitAuthorization
            ?? captureCommitAuthorization(for: observation.source)
        let languageTag = settingsStore.settings.outputLanguageTag
        let gateMode = OptimizationRuntimePolicy.localGateMode
        let gateStartedAt = Date()
        let gateDecision = await localGate.route(
            LocalGateInput(
                observation: observation,
                languageTag: languageTag,
                isRetry: isRetry,
                requiresVisualContext: false
            ),
            mode: gateMode
        )
        try requireCaptureWork(token: captureBoundaryToken, source: observation.source)
        let gateLatencyMilliseconds = gateDecision.classificationLatencyMilliseconds
            ?? Int(max(0, Date().timeIntervalSince(gateStartedAt) * 1_000))
        localIntelligenceStatus = await localGate.status(languageTag: languageTag, mode: gateMode)
        try requireCaptureWork(token: captureBoundaryToken, source: observation.source)
        if gateDecision.route == .suppressCloud,
           let localDraft = gateDecision.localEventDraftAttempt.draft {
            let localEvent: ActivityEvent?
            do {
                localEvent = try localDraft.makeActivityEvent(
                    from: observation,
                    languageTag: languageTag == "auto" ? Locale.current.identifier : languageTag
                )
            } catch {
                // Validation is repeated at the consumption boundary. Any forbidden
                // or malformed local output fails open to the normal Luna path.
                localEvent = nil
            }
            if let localEvent {
                try requireCaptureWork(token: captureBoundaryToken, source: observation.source)
                try await repository.applyAnalysisMutation(AnalysisPersistenceMutation(
                    observationID: observation.id,
                    event: localEvent,
                    captureCommitAuthorization: commitAuthorization
                ))
                pendingCount = max(0, pendingCount - 1)
                await refresh()
                await recordEventVisibility(event: localEvent, observation: observation, isCritical: false)
                return
            }
        }
        if gateDecision.route == .suppressCloud,
           gateDecision.reason == .clearlyEmpty {
            try requireCaptureWork(token: captureBoundaryToken, source: observation.source)
            try await repository.applyAnalysisMutation(AnalysisPersistenceMutation(
                observationID: observation.id,
                captureCommitAuthorization: commitAuthorization
            ))
            pendingCount = max(0, pendingCount - 1)
            return
        }
        guard !isOpenAIWorkBlocked else {
            throw OpenAIClientError.missingAPIKey
        }
        guard let key = try settingsStore.apiKey() else {
            throw OpenAIClientError.missingAPIKey
        }
            var shouldHighlightFollowUp = false
            var persistedEvent: ActivityEvent?
            var persistedCommitments: [Commitment] = []
            var expectedCommitmentRevisions: [UUID: Date] = [:]
            var persistedSubjects: [FollowUpSubject] = []
            var refinementRequest: AnalysisRefinementRequest?
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
            try requireCaptureWork(token: captureBoundaryToken, source: observation.source)
            await recordAppleShadowQualification(
                observation: observation,
                decision: gateDecision,
                interpretation: interpretation,
                localLatencyMilliseconds: gateLatencyMilliseconds
            )
            try requireCaptureWork(token: captureBoundaryToken, source: observation.source)
            // Screen and audio inference may run concurrently, but their
            // repository snapshots must not. Refresh and hold one FIFO gate
            // through consolidation, linking, and the atomic mutation so two
            // Luna responses cannot overwrite each other's evidence or Actions.
            await analysisMutationGate.acquire()
            defer { analysisMutationGate.release() }
            await refresh()
            try requireCaptureWork(token: captureBoundaryToken, source: observation.source)
            let interpretedEvent = interpretation.event
                ?? (interpretation.commitments.isEmpty ? nil : candidateProbe)
            if (interpretation.shouldCreateEvent || !interpretation.commitments.isEmpty),
               let event = interpretedEvent {
                let localConsolidation = await consolidate(event)
                try requireCaptureWork(token: captureBoundaryToken, source: observation.source)
                let usesDeferredTerra = settingsStore.settings.optimizationPhase != .legacy
                    && OptimizationRuntimePolicy.deferredTerraRefinementEnabled
                let shouldRefine: Bool
                if settingsStore.settings.optimizationPhase == .legacy {
                    shouldRefine = interpretation.event != nil && (
                        localConsolidation.importance >= .important
                            || localConsolidation.status == .completed
                            || localConsolidation.kind == .meeting
                            || !interpretation.commitments.isEmpty
                    )
                } else {
                    shouldRefine = !interpretation.eventIsCommitmentFallback && (
                        localConsolidation.importance >= .important
                            || localConsolidation.status == .completed
                            || localConsolidation.kind == .meeting
                    )
                }
                var consolidated = localConsolidation
                // Optimized phases persist Luna immediately and refine a revisioned
                // copy in the background. Legacy preserves the synchronous baseline.
                if shouldRefine, !usesDeferredTerra {
                    do {
                        consolidated = try await ai.refine(
                            event: localConsolidation,
                            outputLanguage: settingsStore.outputLanguagePrompt(),
                            serviceTier: .default,
                            apiKey: key
                        )
                        try requireCaptureWork(token: captureBoundaryToken, source: observation.source)
                    } catch {
                        handleProcessingError(error, context: Self.indicatorContext(for: observation))
                    }
                }
                try requireCaptureWork(token: captureBoundaryToken, source: observation.source)
                persistedEvent = consolidated
                if usesDeferredTerra {
                    if shouldRefine {
                        let observationContext = ActiveContext(
                            applicationName: observation.applicationName,
                            bundleIdentifier: observation.bundleIdentifier,
                            windowTitle: observation.windowTitle,
                            url: observation.url,
                            isMeeting: observation.isMeeting
                        )
                        let containsDeadline = interpretation.commitments.contains {
                            $0.explicitDueAt != nil || $0.operation == .complete
                        } || ObservationRiskSignals.containsDeadlineSignal(
                            text: observation.text,
                            context: observationContext
                        )
                        let isCritical = consolidated.status == .completed
                            || consolidated.importance == .critical
                            || containsDeadline
                        let isMeetingTail = consolidated.kind == .meeting
                            && lastMeetingEndedAt.map { observation.capturedAt <= $0 } == true
                        let delay: TimeInterval = (isCritical || isMeetingTail)
                            ? 0
                            : (consolidated.kind == .meeting ? 5 * 60 : 30)
                        refinementRequest = AnalysisRefinementRequest(
                            eventID: consolidated.id,
                            eventRevision: consolidated.updatedAt,
                            isCritical: isCritical,
                            notBefore: Date().addingTimeInterval(delay)
                        )
                    } else {
                        await optimizationRecorder.record(OptimizationTelemetryRecord(
                            metric: .refinementAvoided,
                            reason: interpretation.eventIsCommitmentFallback ? .commitmentOnly : nil,
                            source: OptimizationTelemetrySource(observation.source),
                            isMeeting: consolidated.kind == .meeting
                        ))
                    }
                }
                var openCommitments = try await repository.commitments(includingClosed: false)
                expectedCommitmentRevisions = Dictionary(
                    openCommitments.map { ($0.id, $0.updatedAt) },
                    uniquingKeysWith: { current, _ in current }
                )
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
                        persistedCommitments.append(linked)
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
                            if resolution.wasCreated { persistedSubjects.append(resolution.subject) }
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
                        persistedCommitments.append(updated)
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
                    if resolution.wasCreated { persistedSubjects.append(resolution.subject) }
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
                    persistedCommitments.append(proposed)
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
        try requireCaptureWork(token: captureBoundaryToken, source: observation.source)
        try await repository.applyAnalysisMutation(AnalysisPersistenceMutation(
            observationID: observation.id,
            event: persistedEvent,
            commitments: persistedCommitments,
            expectedCommitmentRevisions: expectedCommitmentRevisions,
            subjects: persistedSubjects,
            refinement: refinementRequest,
            captureCommitAuthorization: commitAuthorization
        ))
        pendingCount = max(0, pendingCount - 1)
        await refresh()
        if let persistedEvent {
            let visibilityContext = ActiveContext(
                applicationName: observation.applicationName,
                bundleIdentifier: observation.bundleIdentifier,
                windowTitle: observation.windowTitle,
                url: observation.url,
                isMeeting: observation.isMeeting
            )
            let isCritical = persistedEvent.status == .completed
                || persistedEvent.importance == .critical
                || [.purchase, .decision, .task, .appointment].contains(persistedEvent.kind)
                || ObservationRiskSignals.containsHighRiskSignal(
                    text: observation.text,
                    context: visibilityContext
                )
            await recordEventVisibility(
                event: persistedEvent,
                observation: observation,
                isCritical: isCritical
            )
        }
    }

    private func recordEventVisibility(
        event: ActivityEvent,
        observation: Observation,
        isCritical: Bool
    ) async {
        await optimizationRecorder.record(OptimizationTelemetryRecord(
            metric: .eventVisible,
            reason: isCritical ? .criticalEvent : .normalEvent,
            source: OptimizationTelemetrySource(observation.source),
            latencyMilliseconds: Int(max(0, Date().timeIntervalSince(observation.capturedAt)) * 1_000),
            isMeeting: event.kind == .meeting
        ))
    }

    private func recordAppleShadowQualification(
        observation: Observation,
        decision: LocalGateDecision,
        interpretation: InterpretedObservation,
        localLatencyMilliseconds: Int
    ) async {
        guard settingsStore.settings.optimizationPhase == .shadow,
              let repository else { return }
        let verdict: AppleShadowVerdict? = switch decision.verdict {
        case .clearlyEmpty: .clearlyEmpty
        case .uncertain: .uncertain
        case .meaningful: .meaningful
        case nil: nil
        }
        let routeReason: AppleShadowRouteReason = switch decision.reason {
        case .gateDisabled: .gateDisabled
        case .shadowMode: .shadowMode
        case .meeting: .meeting
        case .manualNote: .manualNote
        case .retry: .retry
        case .visualContextRequired: .visualContextRequired
        case .insufficientText: .insufficientText
        case .highRiskSignal: .highRiskSignal
        case .unavailable: .unavailable
        case .unqualifiedModel: .unqualifiedModel
        case .clearlyEmpty: .clearlyEmpty
        case .uncertain: .uncertain
        case .meaningful: .meaningful
        case .generationFailed: .generationFailed
        }
        let cloudMeaningful = interpretation.shouldCreateEvent
            || interpretation.event != nil
            || !interpretation.commitments.isEmpty
        let context = ActiveContext(
            applicationName: observation.applicationName ?? "Unknown",
            bundleIdentifier: observation.bundleIdentifier,
            windowTitle: observation.windowTitle,
            url: observation.url,
            isMeeting: observation.isMeeting
        )
        let isCriticalCase = observation.isMeeting
            || ObservationRiskSignals.containsHighRiskSignal(text: observation.text, context: context)
            || interpretation.event?.status == .completed
            || interpretation.event.map {
                $0.importance >= .important
                    || $0.kind == .purchase
                    || $0.kind == .meeting
                    || $0.kind == .appointment
                    || $0.kind == .decision
                    || $0.kind == .task
            } == true
            || !interpretation.commitments.isEmpty
        let localEventOutcome: AppleShadowLocalEventOutcome = switch decision.localEventDraftAttempt.outcome {
        case .notAttempted: .notAttempted
        case .unqualifiedModel: .unqualifiedModel
        case .generated: .generated
        case .rejectedOutput: .rejectedOutput
        case .generationFailed: .generationFailed
        }
        let generatedDraftIsSafe: Bool = if localEventOutcome == .generated,
                                             let draft = decision.localEventDraftAttempt.draft {
            (try? draft.validated()) != nil
        } else {
            localEventOutcome != .generated
        }
        let localEventSafetyViolation = localEventOutcome == .generated && !generatedDraftIsSafe
        let localEventCriticalMismatch = localEventOutcome == .generated && isCriticalCase
        let localEventCloudCompatible: Bool? = if localEventOutcome == .generated {
            if let event = interpretation.event,
               let draft = decision.localEventDraftAttempt.draft {
                interpretation.shouldCreateEvent
                    && !interpretation.eventIsCommitmentFallback
                    && interpretation.commitments.isEmpty
                    && event.status == .observed
                    && event.importance == .normal
                    && Self.isAllowedLocalEventKind(event.kind)
                    && LocalEventSemanticAgreement.isCompatible(draft, with: event)
                    && !isCriticalCase
                    && !localEventSafetyViolation
            } else {
                false
            }
        } else {
            nil
        }
        let isFalseRejection = verdict == .clearlyEmpty && cloudMeaningful
        let isGateDisagreement = isFalseRejection
            || (verdict == .meaningful && !cloudMeaningful)
        let isLocalEventDisagreement = localEventCloudCompatible == false
            || localEventSafetyViolation
        let allowsExamples = switch DistributionEnvironment.buildChannel {
        case .development, .releaseCandidate: true
        case .standalone, .setapp: false
        }
        let generationAttempted = decision.verdict != nil
            || decision.reason == .generationFailed
        let record = AppleShadowQualificationRecord(
            observationID: observation.id,
            modelFingerprint: decision.modelFingerprint,
            verdict: verdict,
            routeReason: routeReason,
            localLatencyMilliseconds: localLatencyMilliseconds,
            generationAttempted: generationAttempted,
            fromCache: decision.fromCache,
            structuredOutputValid: decision.verdict != nil,
            cloudMeaningful: cloudMeaningful,
            isCriticalCase: isCriticalCase,
            localEventOutcome: localEventOutcome,
            localEventLatencyMilliseconds: decision.localEventDraftAttempt.latencyMilliseconds,
            localEventCloudCompatible: localEventCloudCompatible,
            localEventCriticalMismatch: localEventCriticalMismatch,
            localEventSafetyViolation: localEventSafetyViolation,
            exampleText: allowsExamples && (isGateDisagreement || isLocalEventDisagreement)
                ? observation.text
                : nil
        )
        try? await repository.saveAppleShadowQualificationRecord(record)
    }

    private static func isAllowedLocalEventKind(_ kind: EventKind) -> Bool {
        switch kind {
        case .context, .research, .document, .note: true
        case .application, .purchase, .appointment, .communication, .meeting,
             .decision, .task, .other: false
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
        await notifications.configureDailyDigest(
            hour: settingsStore.settings.dailyDigestHour,
            enabled: settingsStore.settings.dailyDigestEnabled
        )
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
            let disposition = Self.retryDisposition(for: clientError, attempts: 1, isFlex: false)
            if disposition.state == .blockedCredentials {
                isOpenAIWorkBlocked = true
                settingsStore.setAPIKeyState(.invalid(Self.openAIBlockedMessage(for: clientError)))
                captureHealth = .error("OpenAI credentials or spending limit need attention.")
                persistOpenAIBlock(clientError)
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

    private func persistOpenAIBlock(_ error: OpenAIClientError) {
        persistOpenAIBlock(
            errorKind: .credentials,
            errorMessage: Self.openAIBlockedMessage(for: error),
            occurredAt: Date()
        )
    }

    private func persistOpenAIBlock(
        errorKind: AnalysisErrorKind,
        errorMessage: String,
        occurredAt: Date
    ) {
        let identifier = UUID()
        pendingOpenAIBlockPersistence[identifier] = PendingOpenAIBlockPersistence(
            errorKind: errorKind,
            errorMessage: String(errorMessage.prefix(500)),
            occurredAt: occurredAt
        )
        scheduleOpenAIBlockPersistence(identifier)
    }

    private func scheduleOpenAIBlockPersistence(_ identifier: UUID) {
        guard openAIBlockPersistenceTasks[identifier] == nil,
              pendingOpenAIBlockPersistence[identifier] != nil else { return }
        let task = Task<Void, Never> { @MainActor [weak self] in
            await self?.runOpenAIBlockPersistence(identifier)
        }
        openAIBlockPersistenceTasks[identifier] = task
    }

    private func runOpenAIBlockPersistence(_ identifier: UUID) async {
        defer { openAIBlockPersistenceTasks.removeValue(forKey: identifier) }
        guard let pending = pendingOpenAIBlockPersistence[identifier],
              let repository else {
            storageError = "The OpenAI safety block could not be persisted because encrypted storage is unavailable."
            return
        }
        for attempt in 1...3 {
            guard !Task.isCancelled else { return }
            do {
                try await repository.blockAllOpenAIJobs(
                    errorKind: pending.errorKind,
                    errorMessage: pending.errorMessage,
                    at: pending.occurredAt
                )
                pendingOpenAIBlockPersistence.removeValue(forKey: identifier)
                return
            } catch {
                guard attempt < 3 else {
                    storageError = "The OpenAI safety block could not be persisted: \(error.localizedDescription)"
                    return
                }
                try? await Task.sleep(for: .milliseconds(100 * attempt))
            }
        }
    }

    private func waitForOpenAIBlockPersistence() async -> Bool {
        for identifier in pendingOpenAIBlockPersistence.keys
            where openAIBlockPersistenceTasks[identifier] == nil {
            scheduleOpenAIBlockPersistence(identifier)
        }
        let tasks = Array(openAIBlockPersistenceTasks.values)
        for task in tasks { await task.value }
        return pendingOpenAIBlockPersistence.isEmpty
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
        if isOpenAIWorkBlocked {
            return .error(Self.restoredOpenAIBlockMessage)
        }
        return CaptureHealthResolver.resolve(CaptureHealthInputs(
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
