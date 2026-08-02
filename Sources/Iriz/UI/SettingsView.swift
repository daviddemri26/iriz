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
    @State private var pendingExport: ExportFormat?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Settings").font(.largeTitle.weight(.bold))
                    Text("Iriz is local first. You decide what it can observe and what leaves your Mac.")
                        .foregroundStyle(.secondary)
                }
                if app.secureStorageState != .ready { secureStorageSection }
                apiSection
                captureSection
                languageAndRetention
                permissionsSection
                privacySection
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .onAppear {
            excludedDomains = settings.settings.excludedDomains.sorted().joined(separator: ", ")
            excludedApplications = settings.settings.excludedBundleIdentifiers
                .subtracting(ExclusionPolicy.defaultExcludedBundleIdentifiers)
                .sorted().joined(separator: ", ")
            excludedWindowKeywords = (UserDefaults.standard.stringArray(forKey: "iriz.excludedWindowKeywords") ?? []).joined(separator: ", ")
        }
        .task { await permissionMonitor.monitor() }
        .onExitCommand {
            if isChoosingLanguage {
                withAnimation(.snappy(duration: 0.2)) { isChoosingLanguage = false }
            }
        }
        .alert("Export an unencrypted journal?", isPresented: Binding(
            get: { pendingExport != nil },
            set: { if !$0 { pendingExport = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingExport = nil }
            Button("Export") {
                if let format = pendingExport { Task { await app.exportJournal(format: format) } }
                pendingExport = nil
            }
        } message: {
            Text("The export can contain private event details and URLs. Raw screenshots, audio and API keys are never included.")
        }
    }

    private var secureStorageSection: some View {
        SettingsGroup(
            title: "Secure Storage",
            subtitle: "Automatic checks never open Keychain dialogs. Approval is requested only from this button."
        ) {
            HStack(spacing: 10) {
                Image(systemName: app.secureStorageState == .checking ? "hourglass" : "lock.shield")
                    .foregroundStyle(app.secureStorageState == .needsApproval ? Color.orange : IrizTheme.violet)
                Text(app.secureStorageState.displayName)
                    .font(.callout.weight(.medium))
                Spacer()
                if app.secureStorageState != .checking {
                    Button("Unlock Secure Storage") {
                        Task { await app.unlockSecureStorage() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(IrizTheme.violet)
                }
            }
            if let error = app.storageError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            Text("Local development rebuilds use an ad hoc signature, so macOS may ask again. Release builds use one stable Developer ID identity.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var apiSection: some View {
        SettingsGroup(title: "OpenAI", subtitle: "Your personal paid API key is sent directly to OpenAI and stored only in macOS Keychain.") {
            SecureField(settings.apiKeyState == .missing ? "sk-…" : "Enter a replacement key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
            HStack {
                Circle().fill(apiStateColor).frame(width: 8, height: 8)
                Text(settings.apiKeyState.displayName).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if settings.apiKeyState.canRemove {
                    Button("Remove") {
                        do { try settings.removeAPIKey(); apiKey = "" } catch { message = error.localizedDescription }
                    }
                }
                Button("Save") {
                    do {
                        try settings.saveAPIKey(apiKey)
                        apiKey = ""
                        message = "API key saved securely."
                        Task { await app.retryPending() }
                    } catch { message = error.localizedDescription }
                }
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Test & Save") {
                    let candidate = apiKey
                    Task { await app.testAPIKey(candidate); apiKey = "" }
                }
                .buttonStyle(.borderedProminent).tint(IrizTheme.violet)
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || settings.apiKeyState == .testing)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var captureSection: some View {
        SettingsGroup(title: "Observation", subtitle: "Keyboard input, clipboard and camera are never captured.") {
            Toggle("Observe meaningful screen changes", isOn: $settings.settings.screenCaptureEnabled)
            Picker("Microphone", selection: $settings.settings.audioMode) {
                ForEach(AudioMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .onChange(of: settings.settings.audioMode) { _, _ in app.configureAudio() }
            Toggle("Recognize meetings in Zoom, Meet and Teams", isOn: $settings.settings.meetingDetectionEnabled)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recognize your voice as You")
                    Text(app.voiceEnrollmentMessage ?? (settings.settings.voiceEnrollmentEnabled ? "Encrypted sample saved in Keychain." : "Optional 2–10 second sample for diarized meetings."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if settings.settings.voiceEnrollmentEnabled {
                    Button("Remove", action: app.removeVoiceEnrollment)
                }
                Button(app.isEnrollingVoice ? "Listening…" : "Record Sample") {
                    Task { await app.beginVoiceEnrollment() }
                }
                .disabled(app.isEnrollingVoice)
            }
            TextField("Excluded domains, separated by commas", text: $excludedDomains)
                .textFieldStyle(.roundedBorder)
                .onSubmit(saveExcludedDomains)
            TextField("Excluded app bundle IDs, separated by commas", text: $excludedApplications)
                .textFieldStyle(.roundedBorder)
                .onSubmit(saveExcludedDomains)
            TextField("Excluded window title words, separated by commas", text: $excludedWindowKeywords)
                .textFieldStyle(.roundedBorder)
                .onSubmit(saveExcludedDomains)
            HStack {
                Text("Password managers and authentication windows are excluded automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save exclusions", action: saveExcludedDomains)
            }
        }
    }

    private var languageAndRetention: some View {
        SettingsGroup(title: "Journal", subtitle: "The app interface stays in American English. These choices affect generated content and retention.") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Journal language")
                    Spacer()
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { isChoosingLanguage.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Text(settings.outputLanguageDescription())
                            Image(systemName: isChoosingLanguage ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                        }
                    }
                }
                if isChoosingLanguage { inlineLanguagePicker }
            }
            Picker("Keep events and useful transcripts", selection: $settings.settings.structuredRetention) {
                ForEach(StructuredRetention.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker("Daily summary", selection: $settings.settings.dailyDigestHour) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(DateComponents(calendar: .current, hour: hour).date?.formatted(date: .omitted, time: .shortened) ?? "\(hour):00").tag(hour)
                }
            }
            Toggle("Show one quiet daily summary", isOn: $settings.settings.dailyDigestEnabled)
            Toggle("Launch Iriz at login", isOn: Binding(
                get: { settings.settings.launchAtLogin },
                set: { enabled in
                    do { try settings.setLaunchAtLogin(enabled) } catch { message = error.localizedDescription }
                }
            ))
            HStack {
                Text("Raw screenshots and audio are deleted after 24 hours.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Purge expired data now") { Task { await app.cleanup() } }
            }
            HStack {
                Text("Manual export")
                Spacer()
                Button("JSON") { pendingExport = .json }
                Button("Markdown") { pendingExport = .markdown }
            }
            if let exportMessage = app.exportMessage { Text(exportMessage).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var permissionsSection: some View {
        SettingsGroup(title: "Permissions", subtitle: "Each permission is separate and can be changed in System Settings.") {
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
            HStack {
                Text("Statuses refresh automatically, including after you return from System Settings.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { Task { await permissionMonitor.refresh() } }
            }
        }
    }

    private var inlineLanguagePicker: some View {
        VStack(spacing: 8) {
            TextField("Search by language, ISO code or country", text: $languageSearch)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(spacing: 2) {
                    languageButton(title: "Auto — source language", identifier: "auto")
                    Divider().padding(.vertical, 3)
                    ForEach(filteredLanguages) { option in
                        languageButton(title: option.displayName, identifier: option.identifier, code: option.identifier)
                    }
                }
                .padding(6)
            }
            .frame(height: 250)
            .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.08)))
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var filteredLanguages: [LanguageOption] {
        let query = languageSearch.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        guard !query.isEmpty else { return commonLanguages }
        return commonLanguages.filter { $0.searchableText.contains(query) }
    }

    private var commonLanguages: [LanguageOption] {
        let commonIdentifiers = [
            "en-US", "fr-FR", "es-ES", "de-DE", "it-IT", "pt-BR", "nl-NL", "pl-PL",
            "tr-TR", "ru-RU", "ar-SA", "hi-IN", "ja-JP", "ko-KR", "zh-CN"
        ]
        return commonIdentifiers.compactMap { identifier in
            settings.languages.first(where: { $0.identifier == identifier })
        }
    }

    private func languageButton(title: String, identifier: String, code: String? = nil) -> some View {
        Button {
            settings.settings.outputLanguageTag = identifier
            withAnimation(.snappy(duration: 0.2)) { isChoosingLanguage = false }
        } label: {
            HStack(spacing: 10) {
                Text(title).lineLimit(1)
                Spacer()
                if let code { Text(code).font(.caption).foregroundStyle(.secondary) }
                if settings.settings.outputLanguageTag == identifier {
                    Image(systemName: "checkmark").foregroundStyle(IrizTheme.violet)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    private var privacySection: some View {
        SettingsGroup(title: "Privacy", subtitle: "No Iriz account, analytics, or Iriz server is used in this version.") {
            Label("The encrypted journal, full-text index and semantic ranking stay on this Mac.", systemImage: "lock.shield")
            Label("Only selected OCR, transcripts and key screenshots are sent directly to OpenAI for interpretation.", systemImage: "arrow.up.forward")
            Text("API requests use store: false. OpenAI may retain API inputs in abuse-monitoring logs for up to 30 days unless your organization is approved for Zero Data Retention. Inform participants before recording audio and obtain jurisdiction-specific legal advice before distributing Iriz.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var apiStateColor: Color {
        switch settings.apiKeyState {
        case .valid: IrizTheme.mint
        case .invalid: .red
        case .testing: .orange
        case .needsApproval: .orange
        case .checking, .missing, .saved: .secondary
        }
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
        message = "Exclusions saved."
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.weight(.semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(16)
                .background(IrizTheme.card.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

struct PermissionRow: View {
    let title: String
    let state: PermissionState
    var isRequesting = false
    let request: () async -> Void

    var body: some View {
        HStack {
            Image(systemName: state == .granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(state == .granted ? IrizTheme.mint : .secondary)
            Text(title)
            Spacer()
            Text(stateLabel).font(.caption).foregroundStyle(.secondary)
            if state != .granted {
                Button(state == .denied ? "Open Settings" : "Allow") {
                    Task { await request() }
                }
                .disabled(isRequesting)
            }
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
