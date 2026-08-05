import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var settings: SettingsStore
    private let primarySections: [MainSection] = [.assistant, .followUp]

    var body: some View {
        Group {
            if settings.settings.hasCompletedOnboarding {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        sidebar
                            .frame(width: ObservationControlMetrics.sidebarWidth, height: geometry.size.height)
                        Divider()
                        detail
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
            } else {
                OnboardingView()
            }
        }
        .frame(minWidth: 900, maxWidth: .infinity, minHeight: 620, maxHeight: .infinity)
        .background(IrizTheme.canvas)
        .task { await app.refresh() }
        .sheet(item: selectedEvent) { event in
            SourceDetailView(event: event)
                .environmentObject(app)
        }
        .alert(
            "These follow-ups may be unrelated",
            isPresented: Binding(
                get: { app.pendingFollowUpMergeConfirmation != nil },
                set: { isPresented in
                    if !isPresented, app.pendingFollowUpMergeConfirmation != nil {
                        app.cancelPendingFollowUpMerge()
                    }
                }
            )
        ) {
            Button("Cancel", role: .cancel) {
                app.cancelPendingFollowUpMerge()
            }
            Button("Merge Anyway", role: .destructive) {
                Task { await app.confirmPendingFollowUpMerge() }
            }
        } message: {
            if let warning = app.pendingFollowUpMergeConfirmation {
                Text(mergeWarningMessage(warning))
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                IrizLogo(size: 32)
                Text("Iriz").font(.title2.weight(.bold))
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            VStack(spacing: 5) {
                ForEach(primarySections) { section in
                    sidebarButton(for: section)
                }
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 8)

            VStack(spacing: 5) {
                sidebarButton(for: .howIrizWorks)
                sidebarButton(for: .settings)
            }
                .padding(.horizontal, 10)

            ObservationControlCard(placement: .sidebar)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        }
        .background(IrizTheme.canvas)
    }

    private func sidebarButton(for section: MainSection) -> some View {
        let isSelected = app.selectedSection == section
        return Button {
            app.selectedSection = section
        } label: {
            Label(section.rawValue, systemImage: section.symbolName)
                .font(.callout.weight(isSelected ? .semibold : .medium))
                .foregroundStyle(Color.primary)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .padding(.horizontal, 10)
                .background(
                    isSelected ? Color.primary.opacity(0.10) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isSelected ? "Selected" : "")
    }

    @ViewBuilder private var detail: some View {
        switch app.selectedSection {
        case .followUp: FollowUpView()
        case .assistant: AssistantView()
        case .howIrizWorks: HowIrizWorksView()
        case .settings: SettingsView()
        }
    }

    private var selectedEvent: Binding<ActivityEvent?> {
        Binding(
            get: { app.presentedEvent },
            set: { value in
                if value == nil { app.closeEvent() }
            }
        )
    }

    private func mergeWarningMessage(_ warning: PendingFollowUpMergeConfirmation) -> String {
        let actions = warning.sourceActions
            .prefix(4)
            .map { "• \($0)" }
            .joined(separator: "\n")
        return "\(warning.reason)\n\n\(actions)\n\nDo you want to merge them anyway?"
    }
}
