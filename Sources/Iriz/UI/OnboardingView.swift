import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var settings: SettingsStore
    @StateObject private var permissionMonitor = PermissionMonitor()
    @State private var step = 0
    @State private var apiKey = ""

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Group {
                switch step {
                case 0: welcome
                case 1: privacy
                case 2: permissions
                default: keySetup
                }
            }
            .frame(maxWidth: 640)
            Spacer()
            HStack {
                if step > 0 { Button("Back") { withAnimation { step -= 1 } } }
                Spacer()
                Button(step == 3 ? "Start with Iriz" : "Continue") {
                    if step == 3 {
                        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            try? settings.saveAPIKey(apiKey)
                        }
                        settings.settings.hasCompletedOnboarding = true
                        settings.settings.isPaused = false
                        app.resume()
                    } else {
                        withAnimation(.snappy) { step += 1 }
                    }
                }
                .buttonStyle(.borderedProminent).tint(IrizTheme.violet)
            }
            .padding(28)
        }
        .padding(30)
        .task { await permissionMonitor.monitor() }
    }

    private var welcome: some View {
        VStack(spacing: 20) {
            IrizLogo(size: 84)
            Text("Remember what you actually did").font(.system(size: 38, weight: .bold)).multilineTextAlignment(.center)
            Text("Iriz turns meaningful actions, decisions and commitments into a private, searchable memory — while routine app activity stays in the background.")
                .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Local first, by design").font(.system(size: 34, weight: .bold))
            OnboardingPoint(icon: "lock.fill", title: "Encrypted on your Mac", text: "Your memory, search index, screenshots and audio are encrypted locally. Raw media expires after 24 hours.")
            OnboardingPoint(icon: "keyboard", title: "No keyboard or clipboard capture", text: "Iriz never records keystrokes, clipboard contents or camera video.")
            OnboardingPoint(icon: "eye.slash", title: "Sensitive places stay invisible", text: "Password managers and authentication windows are excluded, and you can add apps or domains.")
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Choose what Iriz can observe").font(.system(size: 34, weight: .bold))
            Text("You can enable or revoke each permission separately at any time.").foregroundStyle(.secondary)
            SoftCard {
                VStack(spacing: 14) {
                    PermissionRow(
                        title: "Screen Recording",
                        state: permissionMonitor.snapshot.screenRecording,
                        isRequesting: permissionMonitor.requestedPermission == .screenRecording
                    ) {
                        await permissionMonitor.request(.screenRecording)
                    }
                    PermissionRow(
                        title: "Accessibility",
                        state: permissionMonitor.snapshot.accessibility,
                        isRequesting: permissionMonitor.requestedPermission == .accessibility
                    ) {
                        await permissionMonitor.request(.accessibility)
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
                        title: "Notifications",
                        state: permissionMonitor.snapshot.notifications,
                        isRequesting: permissionMonitor.requestedPermission == .notifications
                    ) {
                        await permissionMonitor.request(.notifications)
                    }
                }
            }
            Text("When audio is enabled, you are responsible for informing participants and complying with local law.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var keySetup: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connect your OpenAI account").font(.system(size: 34, weight: .bold))
            Text("Enter your paid API key. It is stored only in macOS Keychain and requests go directly from this Mac to OpenAI. You can also add it later in Settings.")
                .foregroundStyle(.secondary)
            SecureField("sk-…", text: $apiKey).textFieldStyle(.roundedBorder).font(.title3)
            Label("Iriz sends store: false with every analysis request.", systemImage: "checkmark.shield")
                .font(.callout).foregroundStyle(.secondary)
            if app.secureStorageState == .needsApproval {
                HStack {
                    Label("Keychain approval is required for encrypted memory.", systemImage: "lock.shield")
                    Spacer()
                    Button("Unlock Secure Storage") {
                        Task { await app.unlockSecureStorage() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(IrizTheme.violet)
                }
            }
        }
    }
}

private struct OnboardingPoint: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title2).foregroundStyle(IrizTheme.violet).frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary)
            }
        }
    }
}
