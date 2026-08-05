import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var settings: SettingsStore
    @StateObject private var permissionMonitor = PermissionMonitor()
    @State private var apiKey = ""
    @State private var isChoosingLanguage = false
    @State private var languageSearch = ""
    @State private var excludedDomains = ""
    @State private var excludedApplications = ""
    @State private var excludedWindowKeywords = ""
    @State private var message: String?
    @State private var messageIsError = false
    @State private var pendingExport: ExportFormat?
    @State private var isConfirmingFollowUpReset = false

    private let wideNavigationThreshold: CGFloat = 1_040

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                settingsHeader
                Divider()

                if geometry.size.width >= wideNavigationThreshold {
                    HStack(spacing: 0) {
                        SettingsCategoryNavigation(selection: $app.selectedSettingsCategory)
                            .frame(width: 252)
                        Divider()
                        settingsPage(horizontalPadding: 34)
                    }
                } else {
                    VStack(spacing: 0) {
                        CompactSettingsCategoryNavigation(selection: $app.selectedSettingsCategory)
                        Divider()
                        settingsPage(horizontalPadding: 22)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(IrizTheme.canvas)
        .onAppear(perform: loadEditableBoundaries)
        .task { await permissionMonitor.monitor() }
        .onChange(of: settings.settings.audioSchedule) { _, _ in
            app.configureAudio()
        }
        .onChange(of: settings.settings.meetingDetectionEnabled) { _, _ in
            app.configureAudio()
        }
        .onChange(of: settings.settings.dailyDigestEnabled) { _, _ in
            app.updateDailyDigestSchedule()
        }
        .onChange(of: settings.settings.dailyDigestHour) { _, _ in
            app.updateDailyDigestSchedule()
        }
        .alert("Export unencrypted memory data?", isPresented: Binding(
            get: { pendingExport != nil },
            set: { if !$0 { pendingExport = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingExport = nil }
            Button("Export") {
                if let format = pendingExport { Task { await app.exportMemory(format: format) } }
                pendingExport = nil
            }
        } message: {
            Text("The export can contain private event details and URLs. Raw screenshots, audio and API keys are never included.")
        }
        .alert("Reset Actions?", isPresented: $isConfirmingFollowUpReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset Actions", role: .destructive) {
                Task { await app.resetFollowUps() }
            }
        } message: {
            Text("This clears every Action and subject, but keeps your memory data, media, conversations, API key, and settings.")
        }
    }

    private var settingsHeader: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Settings")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("A clear view of what iriz observes, remembers and shares.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(IrizTheme.mint)
                VStack(alignment: .leading, spacing: 0) {
                    Text("LOCAL-FIRST")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(0.8)
                    Text("You stay in control")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Color.primary.opacity(0.07))
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 18)
    }

    private func settingsPage(horizontalPadding: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    categoryHeader
                        .id("settings-page-top")

                    if app.secureStorageState != .ready {
                        secureStorageNotice
                    }

                    if let message {
                        SettingsFeedbackBanner(message: message, isError: messageIsError) {
                            withAnimation(.easeOut(duration: 0.16)) { self.message = nil }
                        }
                    }

                    selectedCategoryContent
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 28)
                .padding(.bottom, 42)
                .frame(maxWidth: 940, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .scrollIndicators(.automatic)
            .onChange(of: app.selectedSettingsCategory) { _, _ in
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("settings-page-top", anchor: .top)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var categoryHeader: some View {
        HStack(alignment: .top, spacing: 15) {
            Image(systemName: app.selectedSettingsCategory.symbolName)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(app.selectedSettingsCategory.tint)
                .frame(width: 42, height: 42)
                .background(
                    app.selectedSettingsCategory.tint.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 5) {
                Text(app.selectedSettingsCategory.rawValue)
                    .font(.title2.weight(.bold))
                Text(app.selectedSettingsCategory.pageDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var selectedCategoryContent: some View {
        switch app.selectedSettingsCategory {
        case .general:
            quickAccessSection
            appRhythmSection
        case .capture:
            liveCaptureSection
            captureTimingSection
            meetingsSection
        case .intelligence:
            apiSection
            languageSection
        case .actions:
            actionDetailSection
            actionWorkspaceSection
        case .memory:
            retentionSection
            exportSection
        case .privacy:
            permissionsSection
            exclusionsSection
            privacySection
        }
    }

    private var quickAccessSection: some View {
        SettingsCard(
            title: "Quick access",
            subtitle: "Choose where the shared iriz controls are available.",
            symbol: "cursorarrow.motionlines",
            tint: IrizTheme.violet
        ) {
            SettingsControlRow(
                symbol: "menubar.rectangle",
                tint: IrizTheme.violet,
                title: "Menu Bar Icon",
                detail: "A compact iriz menu with Pause, Observe, Listen, Actions and Ask iriz."
            ) {
                Toggle("Menu Bar Icon", isOn: $settings.settings.showMenuBarItem)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            SettingsRowDivider()
            SettingsControlRow(
                symbol: "circle.circle",
                tint: IrizTheme.observingAndListening,
                title: "Floating Bubble",
                detail: "A live indicator that expands to the shared control card when you need it."
            ) {
                Toggle("Floating Bubble", isOn: $settings.settings.showFloatingBubble)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            SettingsCallout(
                symbol: "info.circle",
                text: "Both are enabled by default. Hiding them does not pause iriz; the main window and Dock icon remain available."
            )
        }
    }

    private var appRhythmSection: some View {
        SettingsCard(
            title: "App rhythm",
            subtitle: "Keep iriz available without making it noisy.",
            symbol: "clock.badge.checkmark",
            tint: IrizTheme.mint
        ) {
            SettingsControlRow(
                symbol: "power",
                tint: IrizTheme.mint,
                title: "Launch iriz at login",
                detail: "Start quietly after you sign in to this Mac."
            ) {
                Toggle("Launch iriz at login", isOn: Binding(
                    get: { settings.settings.launchAtLogin },
                    set: { enabled in
                        do {
                            try settings.setLaunchAtLogin(enabled)
                        } catch {
                            messageIsError = true
                            message = error.localizedDescription
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
            SettingsRowDivider()
            SettingsControlRow(
                symbol: "sun.max",
                tint: Color.orange,
                title: "Quiet daily summary",
                detail: "Show one useful recap instead of repeated notifications throughout the day."
            ) {
                Toggle("Quiet daily summary", isOn: $settings.settings.dailyDigestEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            SettingsRowDivider()
            SettingsControlRow(
                symbol: "clock",
                tint: Color.orange,
                title: "Summary time",
                detail: settings.settings.dailyDigestEnabled
                    ? "The recap is prepared at this time each day."
                    : "Enable the daily summary to use this time."
            ) {
                Picker("Summary time", selection: $settings.settings.dailyDigestHour) {
                    ForEach(0..<24, id: \.self) { hour in
                        Text(summaryTimeLabel(hour)).tag(hour)
                    }
                }
                .labelsHidden()
                .frame(width: 142)
                .disabled(!settings.settings.dailyDigestEnabled)
            }
        }
    }

    private var liveCaptureSection: some View {
        SettingsCard(
            title: "Live capture",
            subtitle: "These are the same controls used by the floating panel and sidebar.",
            symbol: "dot.radiowaves.left.and.right",
            tint: app.indicatorPresentation.tint
        ) {
            HStack(alignment: .center, spacing: 13) {
                Image(systemName: app.indicatorPresentation.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(app.indicatorPresentation.tint)
                    .frame(width: 36, height: 36)
                    .background(
                        app.indicatorPresentation.tint.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.indicatorPresentation.title)
                        .font(.headline)
                    Text("This is what iriz is doing right now.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                pauseResumeButton
            }

            SettingsRowDivider()
            ObservationChannelsControl(presentation: .settings)
            SettingsCallout(
                symbol: "pause.circle",
                text: "Pause is the master switch. Observe and Listen keep their selection and resume together when capture is allowed."
            )
        }
    }

    @ViewBuilder private var pauseResumeButton: some View {
        if settings.settings.isPaused {
            Button("Resume iriz") {
                app.setPaused(false)
            }
            .buttonStyle(.borderedProminent)
            .tint(IrizTheme.violet)
        } else {
            Button("Pause iriz") {
                app.setPaused(true)
            }
            .buttonStyle(.bordered)
        }
    }

    private var captureTimingSection: some View {
        SettingsCard(
            title: "When iriz runs",
            subtitle: "One timing rule applies consistently to both selected channels.",
            symbol: "calendar.badge.clock",
            tint: IrizTheme.observing
        ) {
            SettingsControlRow(
                symbol: "timer",
                tint: IrizTheme.observing,
                title: "Capture timing",
                detail: settings.settings.captureTiming == .alwaysOn
                    ? "Selected channels can run whenever iriz is not paused."
                    : "Selected channels run only during the schedule below."
            ) {
                Picker("Capture timing", selection: Binding(
                    get: { settings.settings.captureTiming },
                    set: { app.setCaptureTiming($0) }
                )) {
                    ForEach(CaptureTiming.allCases, id: \.self) { timing in
                        Text(timing.displayName).tag(timing)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)
            }

            if settings.settings.captureTiming == .schedule {
                SettingsRowDivider()
                ScheduleEditor(schedule: $settings.settings.audioSchedule)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: settings.settings.captureTiming)
    }

    private var meetingsSection: some View {
        SettingsCard(
            title: "Meetings & voice",
            subtitle: "Improve meeting context while keeping microphone and system audio separate.",
            symbol: "person.2.wave.2",
            tint: IrizTheme.listening
        ) {
            SettingsControlRow(
                symbol: "video",
                tint: IrizTheme.listening,
                title: "Recognize meetings",
                detail: "Detect Zoom, Google Meet and Microsoft Teams so meeting audio can be interpreted correctly."
            ) {
                Toggle("Recognize meetings", isOn: $settings.settings.meetingDetectionEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            SettingsRowDivider()
            SettingsControlRow(
                symbol: "waveform.badge.person.crop",
                tint: IrizTheme.voiceSignalHighlight,
                title: "Recognize your voice as You",
                detail: app.voiceEnrollmentMessage
                    ?? (settings.settings.voiceEnrollmentEnabled
                        ? "An encrypted voice sample is stored in Keychain."
                        : "Optional 2–10 second sample for diarized meetings.")
            ) {
                HStack(spacing: 8) {
                    if settings.settings.voiceEnrollmentEnabled {
                        Button("Remove", action: app.removeVoiceEnrollment)
                    }
                    Button(app.isEnrollingVoice ? "Listening…" : "Record Sample") {
                        Task { await app.beginVoiceEnrollment() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(IrizTheme.violet)
                    .disabled(app.isEnrollingVoice)
                }
            }
            SettingsCallout(
                symbol: "lock",
                text: "The voice reference is encrypted. It is used only to label your speech during multi-speaker transcription."
            )
        }
    }

    private var apiSection: some View {
        SettingsCard(
            title: "OpenAI connection",
            subtitle: "Use your personal paid API key. It is stored only in macOS Keychain.",
            symbol: "key.horizontal",
            tint: IrizTheme.apiHighlight
        ) {
            HStack(spacing: 10) {
                Circle()
                    .fill(apiStateColor)
                    .frame(width: 9, height: 9)
                Text(settings.apiKeyState.displayName)
                    .font(.callout.weight(.medium))
                Spacer()
            }
            .accessibilityElement(children: .combine)

            VStack(alignment: .leading, spacing: 7) {
                Text("API key")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                SecureField(settings.apiKeyState == .missing ? "sk-…" : "Enter a replacement key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 9) { apiKeyActions }
                VStack(alignment: .leading, spacing: 9) { apiKeyActions }
            }

            DisclosureGroup {
                Text("Luna handles frequent observation classification, Terra is reserved for meaningful memory refinement and answers that need more judgment, and dedicated speech models handle transcription. Each task has a fixed quality and cost budget, so model selection is automatic.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 7)
            } label: {
                Label("How cost-aware model routing works", systemImage: "gauge.with.dots.needle.33percent")
                    .font(.callout.weight(.medium))
            }
        }
    }

    @ViewBuilder private var apiKeyActions: some View {
        if settings.apiKeyState.canRemove {
            Button("Remove Key") {
                do {
                    try settings.removeAPIKey()
                    apiKey = ""
                    messageIsError = false
                    message = "The API key was removed from Keychain."
                } catch {
                    messageIsError = true
                    message = error.localizedDescription
                }
            }
        }
        Spacer(minLength: 0)
        Button("Save") {
            do {
                try settings.saveAPIKey(apiKey)
                apiKey = ""
                messageIsError = false
                message = "API key saved securely."
                Task { await app.retryPending() }
            } catch {
                messageIsError = true
                message = error.localizedDescription
            }
        }
        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Button("Test & Save") {
            let candidate = apiKey
            Task {
                await app.testAPIKey(candidate)
                apiKey = ""
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(IrizTheme.violet)
        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || settings.apiKeyState == .testing)
    }

    private var languageSection: some View {
        SettingsCard(
            title: "Memory & speech language",
            subtitle: "The interface stays in American English. This choice guides generated content and speech recognition.",
            symbol: "character.bubble",
            tint: IrizTheme.voiceSignalHighlight
        ) {
            SettingsControlRow(
                symbol: "globe",
                tint: IrizTheme.voiceSignalHighlight,
                title: "Usual language",
                detail: "iriz treats this as a strong hint, not a restriction when another language is clearly used."
            ) {
                Button {
                    isChoosingLanguage.toggle()
                } label: {
                    HStack(spacing: 7) {
                        Text(currentLanguageLabel)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.bordered)
                .popover(isPresented: $isChoosingLanguage, arrowEdge: .bottom) {
                    LanguagePickerPopover(
                        search: $languageSearch,
                        languages: commonLanguages,
                        selectedIdentifier: settings.settings.outputLanguageTag
                    ) { identifier in
                        settings.settings.outputLanguageTag = identifier
                        isChoosingLanguage = false
                    }
                }
            }
            SettingsCallout(
                symbol: "waveform",
                text: "The same hint helps journal summaries, meeting interpretation, voice sessions and Ask iriz remain consistent."
            )
        }
    }

    private var actionDetailSection: some View {
        SettingsCard(
            title: "Action detail",
            subtitle: "Choose how selective iriz should be when creating new Actions.",
            symbol: "scope",
            tint: IrizTheme.violet
        ) {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    Picker("Action detail", selection: $settings.settings.followUpDetailLevel) {
                        ForEach(FollowUpDetailLevel.allCases) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)

                    Picker("Action detail", selection: $settings.settings.followUpDetailLevel) {
                        ForEach(FollowUpDetailLevel.allCases) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    .pickerStyle(.menu)
                }

                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(IrizTheme.mint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(settings.settings.followUpDetailLevel.displayName)
                            .font(.callout.weight(.semibold))
                        Text(settings.settings.followUpDetailLevel.description)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            SettingsCallout(
                symbol: "arrow.forward.circle",
                text: "This applies only when a new Action is created. Existing Actions keep the scope and wording used when they were found."
            )
        }
    }

    private var actionWorkspaceSection: some View {
        SettingsCard(
            title: "Actions workspace",
            subtitle: "Start over without removing the memory that iriz learned from.",
            symbol: "arrow.counterclockwise",
            tint: IrizTheme.coral
        ) {
            SettingsControlRow(
                symbol: "trash",
                tint: IrizTheme.coral,
                title: "Reset Actions",
                detail: "Clears every Action, subject and Action filter. Memory history, media, conversations, API key and settings are preserved."
            ) {
                Button("Reset Actions…", role: .destructive) {
                    isConfirmingFollowUpReset = true
                }
            }
        }
    }

    private var retentionSection: some View {
        SettingsCard(
            title: "Retention & cleanup",
            subtitle: "Useful structured memories and raw media have separate lifetimes.",
            symbol: "externaldrive.badge.timemachine",
            tint: IrizTheme.mint
        ) {
            SettingsControlRow(
                symbol: "calendar",
                tint: IrizTheme.mint,
                title: "Useful memories",
                detail: "Keep structured events and useful transcripts for this long."
            ) {
                Picker("Useful memories", selection: $settings.settings.structuredRetention) {
                    ForEach(StructuredRetention.allCases, id: \.self) { retention in
                        Text(retention.displayName).tag(retention)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
            }
            SettingsRowDivider()
            SettingsControlRow(
                symbol: "photo.on.rectangle.angled",
                tint: IrizTheme.observing,
                title: "Raw screenshots & audio",
                detail: "Encrypted source media is automatically deleted after 24 hours."
            ) {
                Text("24 hours")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.055), in: Capsule())
            }
            SettingsRowDivider()
            SettingsControlRow(
                symbol: "trash.slash",
                tint: Color.orange,
                title: "Remove expired data now",
                detail: "Runs the same safe cleanup iriz performs automatically."
            ) {
                Button("Purge Now") { Task { await app.cleanup() } }
            }
        }
    }

    private var exportSection: some View {
        SettingsCard(
            title: "Manual export",
            subtitle: "Create a portable copy when you explicitly need one.",
            symbol: "square.and.arrow.up",
            tint: IrizTheme.apiHighlight
        ) {
            SettingsControlRow(
                symbol: "doc.text",
                tint: IrizTheme.apiHighlight,
                title: "Export memory data",
                detail: "Choose structured JSON or a readable Markdown document."
            ) {
                HStack(spacing: 8) {
                    Button("JSON") { pendingExport = .json }
                    Button("Markdown") { pendingExport = .markdown }
                }
            }
            SettingsCallout(
                symbol: "exclamationmark.triangle",
                text: "Exports are unencrypted and may contain private event details and URLs. Raw media and API keys are never included.",
                tint: Color.orange
            )
            if let exportMessage = app.exportMessage {
                Text(exportMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var permissionsSection: some View {
        SettingsCard(
            title: "macOS permissions",
            subtitle: "Each permission is separate. iriz refreshes these statuses when you return from System Settings.",
            symbol: "checkmark.shield",
            tint: IrizTheme.mint
        ) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 235), spacing: 10)], spacing: 10) {
                PermissionRow(
                    title: "Screen Recording",
                    state: permissionMonitor.snapshot.screenRecording,
                    isRequesting: permissionMonitor.requestedPermission == .screenRecording
                ) {
                    await permissionMonitor.request(.screenRecording)
                }
                PermissionRow(
                    title: "Microphone",
                    state: permissionMonitor.snapshot.microphone,
                    isRequesting: permissionMonitor.requestedPermission == .microphone
                ) {
                    await permissionMonitor.request(.microphone)
                    app.configureAudio()
                }
                PermissionRow(
                    title: "Accessibility",
                    state: permissionMonitor.snapshot.accessibility,
                    isRequesting: permissionMonitor.requestedPermission == .accessibility
                ) {
                    await permissionMonitor.request(.accessibility)
                }
                PermissionRow(
                    title: "Notifications",
                    state: permissionMonitor.snapshot.notifications,
                    isRequesting: permissionMonitor.requestedPermission == .notifications
                ) {
                    await permissionMonitor.request(.notifications)
                }
            }

            HStack(alignment: .center, spacing: 12) {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(DistributionEnvironment.buildChannel.displayName)
                            .font(.caption.weight(.semibold))
                        Text(DistributionEnvironment.permissionTestingDescription)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: DistributionEnvironment.isAdHocBuild ? "hammer.fill" : "checkmark.seal.fill")
                        .foregroundStyle(DistributionEnvironment.isAdHocBuild ? Color.orange : IrizTheme.mint)
                }
                Spacer(minLength: 12)
                Button("Refresh Statuses") {
                    Task { await permissionMonitor.refresh() }
                }
            }
            .padding(.top, 2)
        }
    }

    private var exclusionsSection: some View {
        SettingsCard(
            title: "Never observe",
            subtitle: "Built-in password manager and authentication exclusions are always active. Add your own boundaries here.",
            symbol: "eye.slash",
            tint: IrizTheme.privateContext
        ) {
            SettingsTextField(
                title: "Domains",
                detail: "Example: bank.com, private.example.com",
                placeholder: "Excluded domains, separated by commas",
                text: $excludedDomains,
                onSubmit: saveExcludedDomains
            )
            SettingsRowDivider()
            SettingsTextField(
                title: "Applications",
                detail: "Use macOS bundle identifiers, such as com.example.PrivateApp.",
                placeholder: "Excluded app bundle IDs, separated by commas",
                text: $excludedApplications,
                onSubmit: saveExcludedDomains
            )
            SettingsRowDivider()
            SettingsTextField(
                title: "Window title words",
                detail: "Skip any window whose title contains one of these words.",
                placeholder: "Excluded window title words, separated by commas",
                text: $excludedWindowKeywords,
                onSubmit: saveExcludedDomains
            )
            HStack {
                Label("Keyboard input, clipboard and camera are never captured.", systemImage: "hand.raised")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button("Save Exclusions", action: saveExcludedDomains)
                    .buttonStyle(.borderedProminent)
                    .tint(IrizTheme.violet)
            }
        }
    }

    private var privacySection: some View {
        SettingsCard(
            title: "How your data moves",
            subtitle: "No iriz account, analytics or iriz server is used in this version.",
            symbol: "lock.shield",
            tint: IrizTheme.mint
        ) {
            PrivacyFactRow(
                symbol: "internaldrive",
                tint: IrizTheme.mint,
                title: "Stored locally",
                detail: "The encrypted memory, full-text index and semantic ranking stay on this Mac."
            )
            SettingsRowDivider()
            PrivacyFactRow(
                symbol: "arrow.up.forward",
                tint: IrizTheme.apiHighlight,
                title: "Selected context only",
                detail: "Only selected OCR, transcripts, key screenshots, and the current assistant question with recent thread context are sent directly to OpenAI."
            )
            SettingsRowDivider()
            PrivacyFactRow(
                symbol: "server.rack",
                tint: IrizTheme.violet,
                title: "No iriz cloud history",
                detail: "API requests use store: false. iriz does not use OpenAI Conversations, Vector Stores or Background Mode."
            )
            SettingsCallout(
                symbol: "exclamationmark.shield",
                text: "OpenAI may retain API inputs in abuse-monitoring logs for up to 30 days unless your organization is approved for Zero Data Retention. Inform participants before recording audio and obtain jurisdiction-specific legal advice before distributing iriz.",
                tint: Color.orange
            )
        }
    }

    private var secureStorageNotice: some View {
        HStack(alignment: .center, spacing: 13) {
            Image(systemName: app.secureStorageState == .checking ? "hourglass" : "lock.shield")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(app.secureStorageState == .needsApproval ? Color.orange : IrizTheme.violet)
                .frame(width: 38, height: 38)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("Secure Storage — \(app.secureStorageState.displayName)")
                    .font(.callout.weight(.semibold))
                Text("Automatic checks never open Keychain dialogs. Approval is requested only from this button.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let storageError = app.storageError {
                    Text(storageError)
                        .font(.caption)
                        .foregroundStyle(IrizTheme.coral)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            if app.secureStorageState != .checking {
                Button("Unlock Secure Storage") {
                    Task { await app.unlockSecureStorage() }
                }
                .buttonStyle(.borderedProminent)
                .tint(IrizTheme.violet)
            }
        }
        .padding(15)
        .background(Color.orange.opacity(0.075), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.orange.opacity(0.22))
        }
    }

    private var commonLanguages: [LanguageOption] {
        LanguageOption.commonOutputIdentifiers.compactMap { identifier in
            settings.languages.first(where: { $0.identifier == identifier })
        }
    }

    private var currentLanguageLabel: String {
        settings.settings.outputLanguageTag == "auto"
            ? "Auto — source language"
            : settings.outputLanguageDescription()
    }

    private var apiStateColor: Color {
        switch settings.apiKeyState {
        case .valid: IrizTheme.mint
        case .invalid: .red
        case .testing, .needsApproval: .orange
        case .checking, .missing, .saved: .secondary
        }
    }

    private func loadEditableBoundaries() {
        excludedDomains = settings.settings.excludedDomains.sorted().joined(separator: ", ")
        excludedApplications = settings.settings.excludedBundleIdentifiers
            .subtracting(ExclusionPolicy.defaultExcludedBundleIdentifiers)
            .sorted()
            .joined(separator: ", ")
        excludedWindowKeywords = (UserDefaults.standard.stringArray(forKey: "iriz.excludedWindowKeywords") ?? [])
            .joined(separator: ", ")
    }

    private func saveExcludedDomains() {
        settings.settings.excludedDomains = Set(excludedDomains.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty })
        let customApplications = Set(excludedApplications.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
        settings.settings.excludedBundleIdentifiers = ExclusionPolicy.defaultExcludedBundleIdentifiers.union(customApplications)
        let windowKeywords = excludedWindowKeywords.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        UserDefaults.standard.set(windowKeywords, forKey: "iriz.excludedWindowKeywords")
        messageIsError = false
        message = "Exclusions saved."
    }

    private func summaryTimeLabel(_ hour: Int) -> String {
        DateComponents(calendar: .current, hour: hour).date?
            .formatted(date: .omitted, time: .shortened) ?? "\(hour):00"
    }
}

private extension SettingsCategory {
    var tint: Color {
        switch self {
        case .general: IrizTheme.violet
        case .capture: IrizTheme.observing
        case .intelligence: IrizTheme.apiHighlight
        case .actions: IrizTheme.mint
        case .memory: Color.orange
        case .privacy: IrizTheme.privateContext
        }
    }
}

private struct SettingsCategoryNavigation: View {
    @Binding var selection: SettingsCategory

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(SettingsCategory.allCases) { category in
                        Button {
                            withAnimation(.easeOut(duration: 0.16)) { selection = category }
                        } label: {
                            HStack(spacing: 11) {
                                Image(systemName: category.symbolName)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(selection == category ? category.tint : Color.secondary)
                                    .frame(width: 25)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(category.rawValue)
                                        .font(.callout.weight(selection == category ? .semibold : .medium))
                                        .foregroundStyle(.primary)
                                    Text(category.navigationDescription)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer(minLength: 4)
                            }
                            .padding(.horizontal, 11)
                            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                            .background(
                                selection == category ? category.tint.opacity(0.105) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                            )
                            .overlay {
                                if selection == category {
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .stroke(category.tint.opacity(0.20))
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(selection == category ? "Selected" : "")
                        .accessibilityAddTraits(selection == category ? .isSelected : [])
                    }
                }
                .padding(12)
            }

            VStack(alignment: .leading, spacing: 5) {
                Label("Private by design", systemImage: "lock.fill")
                    .font(.caption.weight(.semibold))
                Text("Settings are saved locally on this Mac.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.025))
        }
        .background(Color.primary.opacity(0.018))
    }
}

private struct CompactSettingsCategoryNavigation: View {
    @Binding var selection: SettingsCategory

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    ForEach(SettingsCategory.allCases) { category in
                        Button {
                            withAnimation(.easeOut(duration: 0.16)) { selection = category }
                        } label: {
                            Label(category.rawValue, systemImage: category.symbolName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(selection == category ? category.tint : Color.secondary)
                                .padding(.horizontal, 11)
                                .frame(height: 34)
                                .background(
                                    selection == category ? category.tint.opacity(0.11) : Color.primary.opacity(0.035),
                                    in: Capsule()
                                )
                                .overlay {
                                    Capsule().stroke(
                                        selection == category ? category.tint.opacity(0.22) : Color.primary.opacity(0.05)
                                    )
                                }
                        }
                        .buttonStyle(.plain)
                        .id(category)
                        .accessibilityValue(selection == category ? "Selected" : "")
                        .accessibilityAddTraits(selection == category ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.hidden)
            .onAppear {
                proxy.scrollTo(selection, anchor: .center)
            }
            .onChange(of: selection) { _, category in
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(category, anchor: .center)
                }
            }
        }
        .background(Color.primary.opacity(0.018))
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    let content: Content

    init(
        title: String,
        subtitle: String,
        symbol: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(17)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(17)
        }
        .background(IrizTheme.card.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.065))
        }
        .shadow(color: Color.black.opacity(0.035), radius: 8, y: 3)
    }
}

private struct SettingsControlRow<Control: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let control: Control

    init(
        symbol: String,
        tint: Color,
        title: String,
        detail: String,
        @ViewBuilder control: () -> Control
    ) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 13) {
                rowIdentity
                Spacer(minLength: 14)
                control
            }
            VStack(alignment: .leading, spacing: 11) {
                rowIdentity
                control
            }
        }
    }

    private var rowIdentity: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .layoutPriority(1)
    }
}

private struct SettingsTextField: View {
    let title: String
    let detail: String
    let placeholder: String
    @Binding var text: String
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(onSubmit)
        }
    }
}

private struct LanguagePickerPopover: View {
    @Binding var search: String
    let languages: [LanguageOption]
    let selectedIdentifier: String
    let select: (String) -> Void

    private var filteredLanguages: [LanguageOption] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        guard !query.isEmpty else { return languages }
        return languages.filter { $0.searchableText.contains(query) }
    }

    private var showsAuto: Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        return query.isEmpty || "auto source language".contains(query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Memory & speech language")
                    .font(.headline)
                Text("Choose from the focused language catalog.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("Search language, ISO code or country", text: $search)
                .textFieldStyle(.roundedBorder)

            Divider()

            ScrollView {
                LazyVStack(spacing: 3) {
                    if showsAuto {
                        languageButton(
                            title: "Auto — source language",
                            identifier: "auto",
                            code: nil
                        )
                    }

                    ForEach(filteredLanguages) { language in
                        languageButton(
                            title: language.displayName,
                            identifier: language.identifier,
                            code: language.identifier
                        )
                    }

                    if !showsAuto, filteredLanguages.isEmpty {
                        ContentUnavailableView(
                            "No language found",
                            systemImage: "magnifyingglass",
                            description: Text("Try a language name, ISO code or country.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 180)
                    }
                }
            }
            .scrollIndicators(.automatic)
        }
        .padding(16)
        .frame(width: 360, height: 390)
    }

    private func languageButton(title: String, identifier: String, code: String?) -> some View {
        Button {
            select(identifier)
        } label: {
            HStack(spacing: 10) {
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let code {
                    Text(code)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                if selectedIdentifier == identifier {
                    Image(systemName: "checkmark")
                        .foregroundStyle(IrizTheme.violet)
                }
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(
                selectedIdentifier == identifier ? IrizTheme.violet.opacity(0.09) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(selectedIdentifier == identifier ? "Selected" : "")
        .accessibilityAddTraits(selectedIdentifier == identifier ? .isSelected : [])
    }
}

private struct SettingsCallout: View {
    let symbol: String
    let text: String
    var tint: Color = IrizTheme.violet

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct SettingsRowDivider: View {
    var body: some View {
        Divider().padding(.leading, 41)
    }
}

private struct SettingsFeedbackBanner: View {
    let message: String
    let isError: Bool
    let dismiss: () -> Void

    private var tint: Color { isError ? IrizTheme.coral : IrizTheme.apiHighlight }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(tint)
            Text(message)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss message")
        }
        .padding(12)
        .background(tint.opacity(0.075), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tint.opacity(0.18))
        }
    }
}

private struct PrivacyFactRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 31, height: 31)
                .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ScheduleEditor: View {
    @Binding var schedule: AudioSchedule

    private let timeOptions = Array(stride(from: 0, through: 23 * 60 + 30, by: 30))
    private let weekdays: [(value: Int, label: String)] = [
        (2, "Mon"), (3, "Tue"), (4, "Wed"), (5, "Thu"), (6, "Fri"), (7, "Sat"), (1, "Sun")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) {
                    timePicker(title: "Starts", selection: $schedule.startMinutes)
                    timePicker(title: "Ends", selection: $schedule.endMinutes)
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 12) {
                    timePicker(title: "Starts", selection: $schedule.startMinutes)
                    timePicker(title: "Ends", selection: $schedule.endMinutes)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Active days")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(weekdays, id: \.value) { day in
                        let isSelected = schedule.weekdays.contains(day.value)
                        Button(day.label) {
                            if isSelected {
                                schedule.weekdays.remove(day.value)
                            } else {
                                schedule.weekdays.insert(day.value)
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isSelected ? Color.white : Color.secondary)
                        .frame(maxWidth: .infinity, minHeight: 31)
                        .background(
                            isSelected ? IrizTheme.violet : Color.primary.opacity(0.055),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(isSelected ? Color.clear : Color.primary.opacity(0.06))
                        }
                        .accessibilityValue(isSelected ? "Included" : "Excluded")
                    }
                }
            }

            Label(
                schedule.startMinutes > schedule.endMinutes
                    ? "This schedule continues overnight into the next day."
                    : "Outside these hours, selected channels stay ready but capture nothing.",
                systemImage: schedule.startMinutes > schedule.endMinutes ? "moon.stars" : "pause.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color.primary.opacity(0.032), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.055))
        }
    }

    private func timePicker(title: String, selection: Binding<Int>) -> some View {
        HStack(spacing: 9) {
            Text(title)
                .font(.callout.weight(.medium))
            Picker(title, selection: selection) {
                ForEach(timeOptions, id: \.self) { minutes in
                    Text(timeLabel(minutes)).tag(minutes)
                }
            }
            .labelsHidden()
            .frame(width: 125)
        }
    }

    private func timeLabel(_ minutes: Int) -> String {
        let date = Calendar.current.date(from: DateComponents(hour: minutes / 60, minute: minutes % 60))
        return date?.formatted(date: .omitted, time: .shortened)
            ?? "\(minutes / 60):\(String(format: "%02d", minutes % 60))"
    }
}

struct PermissionRow: View {
    let title: String
    let state: PermissionState
    var isRequesting = false
    let request: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 9) {
                Image(systemName: permissionSymbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(state == .granted ? IrizTheme.mint : Color.secondary)
                    .frame(width: 30, height: 30)
                    .background(
                        (state == .granted ? IrizTheme.mint : Color.secondary).opacity(0.09),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .accessibilityHidden(true)
                Text(title)
                    .font(.callout.weight(.semibold))
                Spacer()
                Image(systemName: state == .granted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(state == .granted ? IrizTheme.mint : Color.secondary)
                    .accessibilityHidden(true)
            }

            HStack {
                Text(stateLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if state != .granted {
                    Button(state == .denied ? "Open Settings" : "Allow") {
                        Task { await request() }
                    }
                    .controlSize(.small)
                    .disabled(isRequesting)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(Color.primary.opacity(0.032), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.primary.opacity(0.055))
        }
    }

    private var permissionSymbol: String {
        switch title {
        case "Screen Recording": "rectangle.dashed.badge.record"
        case "Microphone": "mic"
        case "Accessibility": "accessibility"
        case "Notifications": "bell"
        default: "checkmark.shield"
        }
    }

    private var stateLabel: String {
        switch state {
        case .granted: "Allowed"
        case .notDetermined: "Not requested"
        case .denied: "Not allowed"
        }
    }
}
