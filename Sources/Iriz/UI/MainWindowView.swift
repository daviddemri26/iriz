import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Group {
            if settings.settings.hasCompletedOnboarding {
                NavigationSplitView {
                    sidebar
                        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 240)
                } detail: {
                    detail
                }
            } else {
                OnboardingView()
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .background(IrizTheme.canvas)
        .task { await app.refresh() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                IrizLogo(size: 32)
                Text("Iriz").font(.title2.weight(.bold))
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            List(MainSection.allCases, selection: $app.selectedSection) { section in
                Label(section.rawValue, systemImage: section.symbolName)
                    .tag(section)
            }
            .listStyle(.sidebar)

            observationControl
                .padding(12)
        }
    }

    private var observationControl: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.16))
                    Circle()
                        .stroke(statusColor.opacity(0.28), lineWidth: 1)
                    Image(systemName: statusSymbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(statusColor)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle)
                        .font(.subheadline.weight(.semibold))
                    Text(statusDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                Text(settings.settings.isPaused ? "PAUSED" : "LIVE")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(0.7)
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(0.12), in: Capsule())
            }

            if app.pendingCount > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                    Text("\(app.pendingCount) encrypted moment\(app.pendingCount == 1 ? "" : "s") waiting")
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            }

            Button {
                app.setPaused(!settings.settings.isPaused)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: settings.settings.isPaused ? "play.fill" : "pause.fill")
                        .font(.caption.weight(.bold))
                    Text(settings.settings.isPaused ? "Resume Iriz" : "Pause observation")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("⇧⌘P")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .opacity(0.72)
                }
                .padding(.horizontal, 11)
                .frame(maxWidth: .infinity, minHeight: 36)
                .foregroundStyle(settings.settings.isPaused ? Color.white : Color.primary)
                .background {
                    if settings.settings.isPaused {
                        IrizTheme.gradient
                    } else {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.075))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    if !settings.settings.isPaused {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.primary.opacity(0.08))
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint(settings.settings.isPaused ? "Starts observation" : "Stops all observation")
        }
        .padding(13)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(statusColor.opacity(0.055))
                .overlay {
                    LinearGradient(
                        colors: [Color.white.opacity(0.055), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(statusColor.opacity(0.18))
        }
    }

    private var statusTitle: String {
        switch app.captureHealth {
        case .paused: "Iriz is paused"
        case .observing: "Iriz is observing"
        case .listening: "Iriz is listening"
        case .meeting: "Meeting detected"
        case .processing: "A moment stood out"
        case .permissionNeeded: "Permission needed"
        case .error: "Iriz needs attention"
        }
    }

    private var statusDetail: String {
        switch app.captureHealth {
        case .paused: "Nothing is being captured."
        case .observing: "Ready to remember useful moments."
        case .listening: "Listening for useful spoken context."
        case .meeting: "Keeping context from this meeting."
        case .processing: "Turning it into searchable memory."
        case .permissionNeeded(let permission): "Enable \(permission) to restore context."
        case .error: "Open Settings to review the issue."
        }
    }

    private var statusSymbol: String {
        switch app.captureHealth {
        case .paused: "moon.zzz.fill"
        case .observing: "eye.fill"
        case .listening: "waveform"
        case .meeting: "person.2.fill"
        case .processing: "sparkles"
        case .permissionNeeded: "lock.trianglebadge.exclamationmark.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch app.captureHealth {
        case .paused: IrizTheme.violet
        case .observing: IrizTheme.mint
        case .listening: IrizTheme.violet
        case .meeting: IrizTheme.coral
        case .processing: IrizTheme.violet
        case .permissionNeeded, .error: .orange
        }
    }

    @ViewBuilder private var detail: some View {
        switch app.selectedSection {
        case .journal: JournalView()
        case .followUp: FollowUpView()
        case .assistant: AssistantView()
        case .settings: SettingsView()
        }
    }
}
