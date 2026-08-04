import SwiftUI

private enum FollowUpTab: String, CaseIterable, Identifiable {
    case all
    case needsAttention
    case completionSuggested
    case waiting
    case later
    case maybe
    case resolved

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .needsAttention: "Needs attention"
        case .completionSuggested: "Suggested done"
        case .waiting: "Waiting"
        case .later: "Later"
        case .maybe: "Maybe"
        case .resolved: "Resolved"
        }
    }

    var symbol: String {
        switch self {
        case .all: "tray.full"
        case .needsAttention: "exclamationmark.circle"
        case .completionSuggested: "checkmark.circle"
        case .waiting: "hourglass"
        case .later: "clock"
        case .maybe: "questionmark.circle"
        case .resolved: "checkmark.seal"
        }
    }

    func includes(_ state: CommitmentState) -> Bool {
        switch self {
        case .all: state != .completed && state != .dismissed
        case .needsAttention: state == .needsAttention
        case .completionSuggested: state == .completionSuggested
        case .waiting: state == .waiting
        case .later: state == .later
        case .maybe: state == .maybe
        case .resolved: state == .completed
        }
    }
}

struct FollowUpView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var settings: SettingsStore
    @State private var selectedTab: FollowUpTab = .all
    @State private var selectedContextID: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let sourceCommitments = app.commitments + app.resolvedCommitments
            let ranked = FollowUpPrioritizer.ranked(
                commitments: sourceCommitments,
                events: app.events,
                sensitivity: settings.settings.followUpSensitivity,
                now: timeline.date
            )
            let contextGroups = FollowUpContextGrouper.groups(commitments: ranked, events: app.events)
            let selectedContext = contextGroups.first { $0.id == selectedContextID }
            let contextRanked = selectedContext.map { group in
                ranked.filter { group.commitmentIDs.contains($0.id) }
            } ?? ranked
            let visibleOpen = ranked.filter { $0.effectiveState != .completed && $0.effectiveState != .dismissed }
            let matchingTab = contextRanked.filter { selectedTab.includes($0.effectiveState) }
            let displayed = selectedTab == .resolved
                ? matchingTab.sorted { $0.commitment.updatedAt > $1.commitment.updatedAt }
                : matchingTab
            let hiddenCount = max(0, app.commitments.count - visibleOpen.count)

            VStack(spacing: 0) {
                header(visibleCount: visibleOpen.count, hiddenCount: hiddenCount)
                Divider()
                contextBar(groups: contextGroups)
                Divider()
                tabBar(ranked: contextRanked)
                Divider()
                if displayed.isEmpty {
                    emptyState(contextLabel: selectedContext?.label)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if selectedTab == .all {
                                followUpSummary(visibleCount: visibleOpen.count, hiddenCount: hiddenCount)
                            }
                            if selectedTab == .all, selectedContextID == nil {
                                let priorityItems = displayed.filter(\.commitment.isPriority)
                                if !priorityItems.isEmpty {
                                    prioritySectionHeader(count: priorityItems.count)
                                    ForEach(priorityItems) { rankedCommitment in
                                        CommitmentCard(
                                            ranked: rankedCommitment,
                                            showsPriorityBadge: true
                                        )
                                    }
                                }
                                ForEach(contextGroups) { group in
                                    let groupedItems = displayed.filter {
                                        group.commitmentIDs.contains($0.id) && !$0.commitment.isPriority
                                    }
                                    if !groupedItems.isEmpty {
                                        contextSectionHeader(group: group, visibleCount: groupedItems.count)
                                        ForEach(groupedItems) { rankedCommitment in
                                            CommitmentCard(
                                                ranked: rankedCommitment,
                                                showsPriorityBadge: visibleOpen.count > FollowUpPrioritizer.compactListLimit
                                            )
                                        }
                                    }
                                }
                            } else {
                                ForEach(displayed) { rankedCommitment in
                                    CommitmentCard(
                                        ranked: rankedCommitment,
                                        showsPriorityBadge: visibleOpen.count > FollowUpPrioritizer.compactListLimit
                                    )
                                }
                            }
                        }
                        .padding(22)
                    }
                }
            }
        }
    }

    private func contextBar(groups: [FollowUpContextGroup]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                Text("Context")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 2)
                contextButton(id: nil, title: "All", count: groups.reduce(0) { $0 + $1.count })
                ForEach(groups) { group in
                    contextButton(id: group.id, title: group.label, count: group.count)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 9)
        }
        .scrollIndicators(.hidden)
    }

    private func contextButton(id: String?, title: String, count: Int) -> some View {
        let selected = selectedContextID == id
        return Button {
            withAnimation(.snappy(duration: 0.18)) { selectedContextID = id }
        } label: {
            HStack(spacing: 5) {
                Text(title)
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(selected ? Color.white.opacity(0.82) : Color.secondary)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .background(selected ? IrizTheme.violet : Color.primary.opacity(0.045), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) context")
        .accessibilityValue("\(count) items")
    }

    private func header(visibleCount: Int, hiddenCount: Int) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Follow Up").font(.largeTitle.weight(.bold))
                Text("Promises and useful loose ends, reprioritized locally as time and evidence change.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(settings.settings.followUpSensitivity.displayName)
                    .font(.callout.weight(.semibold))
                Text(hiddenCount > 0 ? "\(visibleCount) visible · \(hiddenCount) filtered" : "\(visibleCount) open")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(22)
    }

    private func tabBar(ranked: [RankedCommitment]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                ForEach(FollowUpTab.allCases) { tab in
                    let count = ranked.filter { tab.includes($0.effectiveState) }.count
                    Button {
                        withAnimation(.snappy(duration: 0.18)) { selectedTab = tab }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tab.symbol)
                            Text(tab.title)
                            Text("\(count)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(selectedTab == tab ? Color.white.opacity(0.82) : Color.secondary)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(selectedTab == tab ? Color.white : Color.primary)
                        .padding(.horizontal, 11)
                        .frame(minHeight: 32)
                        .background(selectedTab == tab ? IrizTheme.violet : Color.primary.opacity(0.055), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue("\(count) items")
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 11)
        }
        .scrollIndicators(.hidden)
    }

    private func emptyState(contextLabel: String?) -> some View {
        ContentUnavailableView(
            contextLabel.map { "No \(selectedTab.title.lowercased()) items in \($0)" }
                ?? (selectedTab == .all ? "Nothing needs your attention" : "No \(selectedTab.title.lowercased()) items"),
            systemImage: selectedTab.symbol,
            description: Text(selectedTab == .resolved
                              ? "Automatically and manually completed follow-ups appear here."
                              : "Iriz will update this category when new evidence is found.")
        )
    }

    private func contextSectionHeader(group: FollowUpContextGroup, visibleCount: Int) -> some View {
        HStack(spacing: 7) {
            Image(systemName: contextSymbol(for: group.label))
                .foregroundStyle(IrizTheme.violet)
            Text(group.label)
                .font(.headline)
            Text("\(visibleCount)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Spacer()
            Button("View") {
                withAnimation(.snappy(duration: 0.18)) { selectedContextID = group.id }
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.semibold))
            .foregroundStyle(IrizTheme.violet)
        }
        .padding(.top, 8)
    }

    private func prioritySectionHeader(count: Int) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "star.fill")
                .foregroundStyle(IrizTheme.violet)
            Text("Priority")
                .font(.headline)
            Text("\(count)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("Marked by you")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private func contextSymbol(for label: String) -> String {
        switch label {
        case "Work": "briefcase.fill"
        case "Personal": "person.fill"
        case "Family": "person.2.fill"
        case "Travel": "airplane"
        case "Other": "square.grid.2x2"
        default: "folder.fill"
        }
    }

    private func followUpSummary(visibleCount: Int, hiddenCount: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: visibleCount > FollowUpPrioritizer.compactListLimit ? "arrow.up.arrow.down.circle.fill" : "checklist.checked")
                .foregroundStyle(IrizTheme.violet)
            VStack(alignment: .leading, spacing: 2) {
                Text(visibleCount > FollowUpPrioritizer.compactListLimit ? "Priority view is active" : "All matching open items are visible")
                    .font(.callout.weight(.semibold))
                Text(hiddenCount > 0
                     ? "\(hiddenCount) lower-sensitivity item\(hiddenCount == 1 ? " is" : "s are") hidden, not deleted. Change sensitivity in Settings to show them."
                     : "Items move between tabs automatically as dates and completion evidence change.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(IrizTheme.violet.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct CommitmentCard: View {
    @EnvironmentObject private var app: AppState
    let ranked: RankedCommitment
    let showsPriorityBadge: Bool

    private var commitment: Commitment { ranked.commitment }
    private var sourceEvent: ActivityEvent? {
        let evidenceID = commitment.linkedEventIDs.last ?? commitment.eventID
        return app.events.first(where: { $0.id == evidenceID })
    }

    var body: some View {
        SoftCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: stateSymbol)
                        .foregroundStyle(stateTint)
                        .frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text(commitment.action)
                                .font(.headline)
                                .fixedSize(horizontal: false, vertical: true)
                            if commitment.isPriority || (ranked.isHighlighted && showsPriorityBadge) {
                                priorityBadge
                            }
                        }
                        if !commitment.rationale.isEmpty {
                            Text(commitment.rationale)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(spacing: 12) {
                            if let date = commitment.explicitDueAt ?? commitment.suggestedReviewAt {
                                Label(date.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                            }
                            Label(FollowUpContextGrouper.label(for: commitment, event: sourceEvent), systemImage: "folder")
                        }
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Text(ranked.reason)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(reasonTint)
                            if let sourceEvent {
                                Button {
                                    app.openEvent(sourceEvent.id)
                                } label: {
                                    Label(sourceEvent.title, systemImage: "arrow.up.forward.square")
                                        .lineLimit(1)
                                }
                                .buttonStyle(.plain)
                                .font(.caption)
                                .foregroundStyle(IrizTheme.violet)
                            }
                        }
                    }
                    Spacer(minLength: 8)
                }
                Divider()
                quickActions
            }
        }
    }

    private var priorityBadge: some View {
        Text(commitment.isPriority ? "PRIORITY" : "TOP")
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .tracking(0.6)
            .foregroundStyle(IrizTheme.violet)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(IrizTheme.violet.opacity(0.12), in: Capsule())
            .fixedSize()
    }

    @ViewBuilder private var quickActions: some View {
        if ranked.effectiveState == .completed {
            HStack {
                Label("Resolved", systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(IrizTheme.mint)
                Spacer()
            }
        } else {
            HStack(spacing: 8) {
                Button {
                    Task { await app.setCommitmentPriority(commitment, isPriority: !commitment.isPriority) }
                } label: {
                    Label(commitment.isPriority ? "Prioritized" : "Priority", systemImage: commitment.isPriority ? "star.fill" : "star")
                }
                .buttonStyle(.bordered)
                .tint(IrizTheme.violet)
                .help(commitment.isPriority ? "Remove manual priority" : "Move this follow-up to the top")

                Button {
                    Task { await app.updateCommitment(commitment, state: .completed) }
                } label: {
                    Label(ranked.effectiveState == .completionSuggested ? "Confirm Done" : "Done", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .tint(IrizTheme.mint)

                Button {
                    Task { await app.updateCommitment(commitment, state: .dismissed) }
                } label: {
                    Label("Dismiss", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .help("Remove this follow-up from the active list")

                Spacer(minLength: 4)

                Menu {
                    if ranked.effectiveState == .completionSuggested {
                        Button("Keep Open") { Task { await app.updateCommitment(commitment, state: .needsAttention) } }
                        Divider()
                    }
                    Button("Waiting for someone or something") {
                        Task { await app.updateCommitment(commitment, state: .waiting) }
                    }
                    Divider()
                    Button("Snooze until tomorrow") { Task { await app.snoozeCommitment(commitment, days: 1) } }
                    Button("Snooze until next week") { Task { await app.snoozeCommitment(commitment, days: 7) } }
                    Button("Move to Later without a date") { Task { await app.updateCommitment(commitment, state: .later) } }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .controlSize(.small)
        }
    }

    private var stateSymbol: String {
        switch ranked.effectiveState {
        case .completionSuggested: "checkmark.circle"
        case .completed: "checkmark.seal.fill"
        case .maybe: "questionmark.circle"
        case .waiting: "hourglass"
        case .later: "clock"
        case .needsAttention: "circle.dashed.inset.filled"
        case .dismissed: "xmark.circle"
        }
    }

    private var stateTint: Color {
        switch ranked.effectiveState {
        case .completionSuggested: .orange
        case .completed: IrizTheme.mint
        case .maybe: .orange
        default: IrizTheme.violet
        }
    }

    private var reasonTint: Color {
        switch ranked.effectiveState {
        case .needsAttention, .completionSuggested: .orange
        case .completed: IrizTheme.mint
        default: .secondary
        }
    }
}
