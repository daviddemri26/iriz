import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var settings: SettingsStore
    private let primarySections: [MainSection] = [.assistant, .followUp, .journal]

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

            sidebarButton(for: .settings)
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
        case .journal: JournalView()
        case .followUp: FollowUpView()
        case .assistant: AssistantView()
        case .settings: SettingsView()
        }
    }
}
