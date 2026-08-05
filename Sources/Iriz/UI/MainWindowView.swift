import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var settings: SettingsStore
    @State private var hoveredPrimarySection: MainSection?
    private let primarySections: [MainSection] = [.followUp, .assistant]

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
            "These Actions may be unrelated",
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
            VStack(alignment: .leading, spacing: 10) {
                ForEach(primarySections) { section in
                    primaryFeatureButton(for: section)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 16)

            if app.pinnedAssistantConversations.isEmpty {
                Spacer(minLength: 8)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(app.pinnedAssistantConversations) { conversation in
                            pinnedConversationRow(conversation)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: .infinity)
            }

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

    private func primaryFeatureButton(for section: MainSection) -> some View {
        let isSelected = app.selectedSection == section
        let isHovered = hoveredPrimarySection == section
        let isFollowUp = section == .followUp
        let colors = isFollowUp
            ? [IrizTheme.observing.opacity(0.92), IrizTheme.mint.opacity(0.88)]
            : [IrizTheme.violet.opacity(0.94), IrizTheme.coral.opacity(0.86)]
        let subtitle = isFollowUp
            ? "Keep important next steps moving"
            : "Search your memory with sourced answers"
        let eyebrow = isFollowUp ? "YOUR PRIORITIES" : "YOUR MEMORY"
        let symbol = isFollowUp ? "checkmark.circle.fill" : "sparkles"

        return Button {
            app.selectedSection = section
        } label: {
            ZStack(alignment: .trailing) {
                LinearGradient(
                    colors: colors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Circle()
                    .fill(Color.white.opacity(0.10))
                    .frame(width: 92, height: 92)
                    .offset(x: 24, y: -20)

                Image(systemName: symbol)
                    .font(.system(size: 35, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.94))
                    .symbolRenderingMode(.hierarchical)
                    .padding(.trailing, 17)
                    .shadow(color: Color.black.opacity(0.16), radius: 8, y: 4)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    Text(eyebrow)
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .tracking(1.1)
                        .foregroundStyle(Color.white.opacity(0.72))
                    Text(section.rawValue)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.82))
                        .lineLimit(2)
                        .frame(maxWidth: 168, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 15)
                .padding(.vertical, 13)
            }
            .frame(maxWidth: .infinity, minHeight: 92)
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(Color.white.opacity(isSelected ? 0.72 : 0.18), lineWidth: isSelected ? 2 : 1)
            }
            .shadow(
                color: colors[0].opacity(isSelected || isHovered ? 0.30 : 0.14),
                radius: isSelected || isHovered ? 12 : 7,
                y: 5
            )
            .scaleEffect(isHovered ? 1.012 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isInside in
            withAnimation(.easeOut(duration: 0.16)) {
                hoveredPrimarySection = isInside ? section : nil
            }
        }
        .animation(.easeOut(duration: 0.18), value: isSelected)
        .accessibilityLabel(section.rawValue)
        .accessibilityHint(subtitle)
        .accessibilityValue(isSelected ? "Selected" : "")
    }

    private func pinnedConversationRow(_ conversation: AssistantConversation) -> some View {
        let isSelected = app.selectedSection == .assistant
            && app.selectedAssistantConversationID == conversation.id

        return HStack(spacing: 3) {
            Button {
                app.selectAssistantConversation(conversation.id)
                app.selectedSection = .assistant
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bubble.left.fill")
                        .font(.caption)
                        .foregroundStyle(isSelected ? Color.white : IrizTheme.violet)
                        .accessibilityHidden(true)
                    Text(conversation.title)
                        .font(.callout.weight(isSelected ? .semibold : .medium))
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 38)
                .padding(.leading, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                Task { await app.setAssistantConversationPinned(conversation.id, isPinned: false) }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.78) : Color.secondary)
                    .frame(width: 28, height: 32)
            }
            .buttonStyle(.plain)
            .help("Unpin conversation")
            .accessibilityLabel("Unpin \(conversation.title)")
        }
        .padding(.trailing, 4)
        .background(
            isSelected ? IrizTheme.violet.opacity(0.86) : Color.primary.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(isSelected ? 0 : 0.07))
        }
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
