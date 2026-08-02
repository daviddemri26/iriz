import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Group {
            if settings.settings.hasCompletedOnboarding {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        sidebar
                            .frame(width: 250, height: geometry.size.height)
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

            ObservationControlCard(placement: .sidebar)
                .padding(12)
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
