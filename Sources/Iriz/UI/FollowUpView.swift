import SwiftUI

struct FollowUpView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var settings: SettingsStore
    @State private var search = ""
    @State private var completedSearch = ""
    @State private var completedActor: FollowUpCompletionActor?
    @State private var completedPeriod: CompletedArchivePeriod = .all
    @State private var selectedFollowUp: Commitment?
    @State private var isCreating = false
    @State private var snoozeTarget: Commitment?
    @State private var isManagingSubjects = false
    @State private var isManagingTypes = false
    @State private var canvasNotice: FollowUpCanvasNotice?
    @State private var canvasNoticeTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        header
                        Divider()
                        filterAndCompletedHeader
                        Divider()
                        if settings.settings.followUpDisplay.completedRailMode == .expanded {
                            completedArchive(now: timeline.date)
                        } else {
                            HStack(spacing: 0) {
                                activeCanvas(now: timeline.date)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                if shouldShowCompletedRail {
                                    Divider()
                                    completedRail(now: timeline.date)
                                        .frame(width: 232)
                                }
                            }
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }

            if let notice = canvasNotice {
                canvasNoticeBanner(notice)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .allowsHitTesting(false)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(5)
            }

            if let commitment = selectedFollowUp {
                Color.black.opacity(0.58)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: closeSelectedFollowUp)
                    .transition(.opacity)
                    .zIndex(10)

                FollowUpDetailView(commitment: commitment) {
                    closeSelectedFollowUp()
                }
                .environmentObject(app)
                .environmentObject(settings)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(.white.opacity(0.18), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.46), radius: 34, y: 18)
                .transition(.scale(scale: 0.975).combined(with: .opacity))
                .accessibilityAddTraits(.isModal)
                .zIndex(11)
            }
        }
        .animation(.snappy(duration: 0.22), value: selectedFollowUp?.id)
        .animation(.snappy(duration: 0.2), value: canvasNotice)
        .sheet(isPresented: $isCreating) {
            NewFollowUpSheet { createdID in
                isCreating = false
                if let createdID,
                   let created = app.commitments.first(where: { $0.id == createdID }) {
                    selectedFollowUp = created
                }
            }
            .environmentObject(app)
        }
        .sheet(item: $snoozeTarget) { commitment in
            CustomSnoozeSheet(commitment: commitment) { snoozeTarget = nil }
                .environmentObject(app)
        }
        .sheet(isPresented: $isManagingSubjects) {
            FollowUpSubjectManager()
                .environmentObject(app)
        }
        .sheet(isPresented: $isManagingTypes) {
            FollowUpTypeManager()
                .environmentObject(app)
        }
        .onDisappear { canvasNoticeTask?.cancel() }
    }

    private var preferences: FollowUpDisplayPreferences {
        settings.settings.followUpDisplay
    }

    private func closeSelectedFollowUp() {
        withAnimation(.snappy(duration: 0.2)) {
            selectedFollowUp = nil
        }
    }

    private func showMergeGuidance() {
        canvasNoticeTask?.cancel()
        withAnimation(.snappy(duration: 0.2)) {
            canvasNotice = .mergeGuidance
        }
        canvasNoticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy(duration: 0.2)) {
                canvasNotice = nil
            }
        }
    }

    private func clearCanvasNotice() {
        canvasNoticeTask?.cancel()
        canvasNoticeTask = nil
        withAnimation(.snappy(duration: 0.18)) {
            canvasNotice = nil
        }
    }

    private func canvasNoticeBanner(_ notice: FollowUpCanvasNotice) -> some View {
        HStack(spacing: 13) {
            Image(systemName: notice.symbol)
                .font(.title2.weight(.bold))
                .foregroundStyle(notice.tint)
            Text(notice.message)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(Color(red: 0.10, green: 0.10, blue: 0.12).opacity(0.94), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.14))
        }
        .shadow(color: .black.opacity(0.34), radius: 18, y: 8)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Actions")
                    .font(.largeTitle.weight(.bold))
                Text("A clear, personal view of what still matters.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let message = app.followUpOperationMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 260, alignment: .trailing)
            }
            VStack(alignment: .trailing, spacing: 5) {
                Button {
                    isCreating = true
                } label: {
                    Label("Add an Action", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(IrizTheme.violet)

                Text("iriz usually creates Actions for you. Add one yourself when needed.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 280, alignment: .trailing)
            }
        }
        .padding(22)
    }

    private var filterAndCompletedHeader: some View {
        HStack(spacing: 0) {
            filterBar
                .frame(maxWidth: .infinity)
            Divider()
            completedRailHeader
                .frame(width: 232)
        }
        .frame(height: 80)
    }

    private var filterBar: some View {
        VStack(spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    viewModePicker(width: 270)
                    typeMenu
                    subjectMenu
                    Spacer(minLength: 8)
                    searchField
                }

                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        viewModePicker(width: 240)
                        Spacer(minLength: 4)
                        typeMenu
                        subjectMenu
                    }
                    searchField
                        .frame(maxWidth: .infinity)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    priorityFilterControls
                    Spacer()
                    chronologyHint
                }

                VStack(alignment: .leading, spacing: 6) {
                    priorityFilterControls
                    chronologyHint
                }
            }
        }
        .padding(.leading, 22)
        .padding(.trailing, 14)
        .padding(.vertical, 12)
    }

    private var completedRailHeader: some View {
        HStack(spacing: 10) {
            completedRailToggleButton
            Spacer(minLength: 0)
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    settings.settings.followUpDisplay.completedRailMode = .expanded
                }
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain)
            .help("Open completed history")
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.018))
    }

    private var completedRailToggleButton: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                settings.settings.followUpDisplay.completedRailMode = isCompletedVisible ? .collapsed : .rail
            }
        } label: {
            Label("Completed \(app.resolvedCommitments.count)", systemImage: "checkmark.seal")
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .help(isCompletedVisible ? "Hide completed Actions" : "Show completed Actions")
    }

    private func viewModePicker(width: CGFloat) -> some View {
        Picker("View", selection: $settings.settings.followUpDisplay.viewMode) {
            ForEach(FollowUpViewMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: width)
    }

    private var searchField: some View {
        TextField("Search Actions", text: $search)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 180, idealWidth: 240, maxWidth: 300)
    }

    private var priorityFilterControls: some View {
        HStack(spacing: 10) {
            Image(systemName: "dial.medium")
                .foregroundStyle(IrizTheme.violet)
            Text("Priority ≥ \(preferences.minimumPriority)")
                .font(.caption.weight(.semibold))
                .frame(width: 82, alignment: .leading)
            Slider(
                value: Binding(
                    get: { Double(preferences.minimumPriority) },
                    set: { settings.settings.followUpDisplay.minimumPriority = Int($0.rounded()) }
                ),
                in: 0...10,
                step: 1
            )
            .frame(minWidth: 160, idealWidth: 280, maxWidth: 340)
            .accessibilityLabel("Minimum displayed priority")
            Text(minimumPriorityLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
        }
    }

    private var chronologyHint: some View {
        Text("Strictly newest first · priority only filters and emphasizes")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var minimumPriorityLabel: String {
        switch preferences.minimumPriority {
        case 8...10: "High only"
        case 5...7: "Medium+"
        case 1...4: "Low+"
        default: "All"
        }
    }

    private var typeMenu: some View {
        Menu {
            Button("All types") { settings.settings.followUpDisplay.selectedTypeIDs = [] }
            Divider()
            ForEach(prioritizedTypes) { type in
                Button {
                    if preferences.selectedTypeIDs.contains(type.id) {
                        settings.settings.followUpDisplay.selectedTypeIDs.remove(type.id)
                    } else {
                        settings.settings.followUpDisplay.selectedTypeIDs.insert(type.id)
                    }
                } label: {
                    if preferences.selectedTypeIDs.contains(type.id) {
                        Label(type.name, systemImage: "checkmark.circle.fill")
                    } else {
                        Label(type.name, systemImage: type.systemImage)
                    }
                }
            }
            Divider()
            Button("Manage types…") { isManagingTypes = true }
        } label: {
            Label(
                preferences.selectedTypeIDs.isEmpty ? "All types" : "\(preferences.selectedTypeIDs.count) types",
                systemImage: "square.stack.3d.up"
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var prioritizedTypes: [FollowUpType] {
        let subjectsByID = Dictionary(uniqueKeysWithValues: app.followUpSubjects.map { ($0.id, $0) })
        let counts = Dictionary(grouping: app.commitments.compactMap { commitment -> String? in
            guard let subjectID = commitment.subjectID,
                  let subject = subjectsByID[subjectID] else {
                return FollowUpType.defaultID(for: commitment.area)
            }
            return subject.typeID ?? FollowUpType.defaultID(for: subject.area)
        }, by: { $0 }).mapValues(\.count)
        return app.followUpTypes.sorted { lhs, rhs in
            let lhsCount = counts[lhs.id] ?? 0
            let rhsCount = counts[rhs.id] ?? 0
            if lhsCount != rhsCount { return lhsCount > rhsCount }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var subjectMenu: some View {
        Menu {
            Button("All subjects") {
                settings.settings.followUpDisplay.selectedSubjectIDs = []
            }
            Divider()
            ForEach(prioritizedSubjects) { subject in
                Button {
                    if preferences.selectedSubjectIDs.contains(subject.id) {
                        settings.settings.followUpDisplay.selectedSubjectIDs.remove(subject.id)
                    } else {
                        settings.settings.followUpDisplay.selectedSubjectIDs.insert(subject.id)
                    }
                } label: {
                    Label {
                        Text(subject.name)
                    } icon: {
                        Image(systemName: preferences.selectedSubjectIDs.contains(subject.id) ? "checkmark.circle.fill" : "circle.fill")
                    }
                }
            }
            Divider()
            Button("Manage subjects…") { isManagingSubjects = true }
        } label: {
            Label(
                preferences.selectedSubjectIDs.isEmpty ? "All subjects" : "\(preferences.selectedSubjectIDs.count) subjects",
                systemImage: "tag"
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var prioritizedSubjects: [FollowUpSubject] {
        let openCounts = Dictionary(grouping: app.commitments, by: \.subjectID)
            .mapValues(\.count)
        return app.followUpSubjects
            .filter { !FollowUpContextGrouper.isGenericSubjectName($0.name) }
            .sorted { lhs, rhs in
                let lhsCount = openCounts[lhs.id] ?? 0
                let rhsCount = openCounts[rhs.id] ?? 0
                if lhsCount != rhsCount { return lhsCount > rhsCount }
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    @ViewBuilder
    private func activeCanvas(now: Date) -> some View {
        let values = filteredOpenFollowUps(now: now)
        if values.isEmpty {
            ContentUnavailableView(
                emptyTitle,
                systemImage: preferences.viewMode == .active ? "square.grid.2x2" : (preferences.viewMode == .snoozed ? "moon.zzz" : "eye.slash"),
                description: Text("Adjust the filters or create an Action manually.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(minimum: 150), spacing: 12, alignment: .top),
                        count: 3
                    ),
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(values) { commitment in
                        FollowUpTile(
                            commitment: commitment,
                            subject: subject(for: commitment),
                            type: type(for: commitment),
                            onOpen: { selectedFollowUp = commitment },
                            onCustomSnooze: { snoozeTarget = commitment },
                            onDragBegan: showMergeGuidance,
                            onMerge: { sourceID in
                                clearCanvasNotice()
                                Task { await app.mergeFollowUps(ids: [sourceID, commitment.id], targetID: commitment.id) }
                            }
                        )
                    }
                }
                .padding(18)
            }
        }
    }

    private var emptyTitle: String {
        switch preferences.viewMode {
        case .active: "No active Actions match"
        case .snoozed: "Nothing is snoozed"
        case .dismissed: "Nothing is dismissed"
        }
    }

    private func filteredOpenFollowUps(now: Date) -> [Commitment] {
        let lifecycle: FollowUpLifecycle = switch preferences.viewMode {
        case .active: .active
        case .snoozed: .snoozed
        case .dismissed: .dismissed
        }
        return FollowUpPrioritizer.displayOrdered(
            commitments: app.commitments.filter(matchesGlobalFilters),
            lifecycle: lifecycle,
            minimumPriority: preferences.minimumPriority,
            now: now
        )
        .filter(matchesSearch)
    }

    private func matchesGlobalFilters(_ commitment: Commitment) -> Bool {
        (preferences.selectedTypeIDs.isEmpty || preferences.selectedTypeIDs.contains(type(for: commitment).id)) &&
        (preferences.selectedSubjectIDs.isEmpty || commitment.subjectID.map(preferences.selectedSubjectIDs.contains) == true)
    }

    private func matchesSearch(_ commitment: Commitment) -> Bool {
        search.isEmpty || [commitment.action, commitment.summary, commitment.details, commitment.contextLabel ?? ""]
            .joined(separator: " ")
            .localizedCaseInsensitiveContains(search)
    }

    private func subject(for commitment: Commitment) -> FollowUpSubject {
        commitment.subjectID.flatMap { id in app.followUpSubjects.first(where: { $0.id == id }) }
            ?? FollowUpSubject(name: commitment.contextLabel ?? "Uncategorized", area: commitment.area)
    }

    private func type(for commitment: Commitment) -> FollowUpType {
        let subject = subject(for: commitment)
        let identifier = subject.typeID ?? FollowUpType.defaultID(for: subject.area)
        return app.followUpTypes.first(where: { $0.id == identifier })
            ?? FollowUpType.defaults.first(where: { $0.id == FollowUpType.defaultID(for: commitment.area) })!
    }

    private var shouldShowCompletedRail: Bool {
        preferences.completedRailMode == .rail
    }

    private var isCompletedVisible: Bool {
        preferences.completedRailMode != .collapsed
    }

    private func recentCompleted(now: Date) -> [Commitment] {
        let cutoff = now.addingTimeInterval(-preferences.completedRailDuration.interval)
        return app.resolvedCommitments
            .filter(matchesGlobalFilters)
            .filter { ($0.completedAt ?? $0.updatedAt) >= cutoff }
            .filter { $0.priorityScore >= preferences.minimumPriority }
            .sorted { ($0.completedAt ?? $0.updatedAt) > ($1.completedAt ?? $1.updatedAt) }
    }

    private func completedRail(now: Date) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Showing")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Menu(preferences.completedRailDuration.displayName) {
                    ForEach(CompletedRailDuration.allCases) { duration in
                        Button(duration.displayName) {
                            settings.settings.followUpDisplay.completedRailDuration = duration
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(14)
            Divider()

            let values = recentCompleted(now: now)
            if values.isEmpty {
                ContentUnavailableView(
                    "No recent completions",
                    systemImage: "checkmark.seal",
                    description: Text("Completed Actions stay here for \(preferences.completedRailDuration.displayName).")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(values) { commitment in
                            CompletedFollowUpCard(
                                commitment: commitment,
                                subject: subject(for: commitment),
                                compact: true,
                                onOpen: { selectedFollowUp = commitment }
                            )
                        }
                    }
                    .padding(12)
                }
            }
        }
        .background(Color.primary.opacity(0.018))
    }

    private func completedArchive(now: Date) -> some View {
        let values = app.resolvedCommitments
            .filter(matchesGlobalFilters)
            .filter { $0.priorityScore >= preferences.minimumPriority }
            .filter { completedPeriod.includes($0.completedAt ?? $0.updatedAt, relativeTo: now) }
            .filter { completedActor == nil || $0.completionActor == completedActor }
            .filter {
                completedSearch.isEmpty || [
                    $0.action, $0.summary, $0.details, $0.contextLabel ?? "", $0.completionEvidence?.summary ?? ""
                ].joined(separator: " ").localizedCaseInsensitiveContains(completedSearch)
            }
            .sorted { ($0.completedAt ?? $0.updatedAt) > ($1.completedAt ?? $1.updatedAt) }

        return VStack(spacing: 0) {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            settings.settings.followUpDisplay.completedRailMode = .rail
                        }
                    } label: {
                        Label("Back to active", systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Completed History")
                            .font(.title2.weight(.bold))
                        Text("\(values.count) retained completion\(values.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        archiveFilterLabel
                        Spacer(minLength: 8)
                        completedPeriodMenu
                        completedActorPicker
                        completedSearchField
                    }

                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 12) {
                            archiveFilterLabel
                            Spacer(minLength: 8)
                            completedPeriodMenu
                            completedActorPicker
                        }
                        completedSearchField
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(18)
            Divider()

            if values.isEmpty {
                ContentUnavailableView(
                    "No completed Actions match",
                    systemImage: "checkmark.seal",
                    description: Text("This view includes every completion still available under structured retention.")
                )
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 250, maximum: 340), spacing: 14)],
                        spacing: 14
                    ) {
                        ForEach(values) { commitment in
                            CompletedFollowUpCard(
                                commitment: commitment,
                                subject: subject(for: commitment),
                                compact: false,
                                onOpen: { selectedFollowUp = commitment }
                            )
                        }
                    }
                    .padding(22)
                }
            }
        }
    }

    private var archiveFilterLabel: some View {
        Label("Archive filters", systemImage: "line.3.horizontal.decrease.circle")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private var completedPeriodMenu: some View {
        Picker("Period", selection: $completedPeriod) {
            ForEach(CompletedArchivePeriod.allCases) { period in
                Text(period.displayName).tag(period)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .accessibilityLabel("Completion period")
    }

    private var completedActorPicker: some View {
        Picker("Completed by", selection: $completedActor) {
            Text("Everyone").tag(FollowUpCompletionActor?.none)
            Text("You").tag(FollowUpCompletionActor?.some(.user))
            Text("iriz").tag(FollowUpCompletionActor?.some(.iriz))
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 210)
        .accessibilityLabel("Completed by")
    }

    private var completedSearchField: some View {
        TextField("Search completed", text: $completedSearch)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 180, idealWidth: 250, maxWidth: 300)
    }
}

private enum CompletedArchivePeriod: String, CaseIterable, Identifiable {
    case all
    case oneDay
    case sevenDays
    case thirtyDays

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: "All retained time"
        case .oneDay: "Last 24 hours"
        case .sevenDays: "Last 7 days"
        case .thirtyDays: "Last 30 days"
        }
    }

    func includes(_ date: Date, relativeTo now: Date) -> Bool {
        let interval: TimeInterval? = switch self {
        case .all: nil
        case .oneDay: 24 * 3_600
        case .sevenDays: 7 * 24 * 3_600
        case .thirtyDays: 30 * 24 * 3_600
        }
        return interval.map { date >= now.addingTimeInterval(-$0) } ?? true
    }
}

private struct FollowUpCanvasNotice: Equatable {
    let symbol: String
    let message: String
    let tint: Color

    static let mergeGuidance = FollowUpCanvasNotice(
        symbol: "arrow.triangle.merge",
        message: "Drop this tile onto another to merge them.",
        tint: IrizTheme.mint
    )

    static func == (lhs: FollowUpCanvasNotice, rhs: FollowUpCanvasNotice) -> Bool {
        lhs.symbol == rhs.symbol && lhs.message == rhs.message
    }
}

enum FollowUpTilePriorityBand: Equatable {
    case critical
    case elevated
    case standard
}

enum FollowUpCompletionButtonStyle: Equatable {
    case standard
    case suggestedByIriz
}

enum FollowUpTilePresentation {
    static let tileHeight: CGFloat = 205
    static let scheduleSlotHeight: CGFloat = 24

    static func baseOpacity(for priority: Int) -> Double {
        let score = min(max(priority, 0), 10)
        if score >= 6 { return 1 }
        return 0.28 + Double(score) * 0.12
    }

    static func priorityBand(for priority: Int) -> FollowUpTilePriorityBand {
        switch min(max(priority, 0), 10) {
        case 9...10: .critical
        case 7...8: .elevated
        default: .standard
        }
    }

    static func completionButtonStyle(for commitment: Commitment) -> FollowUpCompletionButtonStyle {
        let hint = commitment.evidenceHint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return hint.isEmpty ? .standard : .suggestedByIriz
    }
}

private struct FollowUpTileBackground: View {
    let subjectColor: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color(red: 0.10, green: 0.10, blue: 0.12))
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [subjectColor.opacity(0.34), subjectColor.opacity(0.18)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
    }
}

private struct FollowUpTile: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    let commitment: Commitment
    let subject: FollowUpSubject
    let type: FollowUpType
    let onOpen: () -> Void
    let onCustomSnooze: () -> Void
    let onDragBegan: () -> Void
    let onMerge: (UUID) -> Void
    @State private var isHovered = false
    @State private var isDropTarget = false
    @State private var isUpdatingPriority = false
    @FocusState private var isKeyboardFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 7) {
                subjectChip
                Spacer(minLength: 5)
                exportMenu
            }

            Button(action: openDetails) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(commitment.action)
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, minHeight: 68, alignment: .topLeading)
                    scheduleBadges
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider()
            HStack(alignment: .center, spacing: 7) {
                quickActions
                Spacer(minLength: 4)
                priorityControl
            }
        }
        .padding(13)
        .frame(height: FollowUpTilePresentation.tileHeight, alignment: .top)
        .background {
            FollowUpTileBackground(subjectColor: subject.color.color)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(
                    isDropTarget ? subject.color.color : subject.color.color.opacity(0.30),
                    lineWidth: isDropTarget ? 3 : 1
                )
        }
        .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
        .opacity(tileOpacity)
        .scaleEffect(isDropTarget ? 1.015 : 1)
        .animation(.snappy(duration: 0.16), value: isDropTarget)
        .onHover { isHovered = $0 }
        .focusable()
        .focused($isKeyboardFocused)
        .focusEffectDisabled()
        .onKeyPress(.return) {
            openDetails()
            return .handled
        }
        .onDrag {
            clearPointerEmphasis()
            onDragBegan()
            return NSItemProvider(object: commitment.id.uuidString as NSString)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let rawID = items.first,
                  let sourceID = UUID(uuidString: rawID),
                  sourceID != commitment.id else { return false }
            onMerge(sourceID)
            return true
        } isTargeted: { isDropTarget = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(commitment.action), priority \(commitment.priorityScore) out of 10, \(subject.name)")
    }

    private var tileOpacity: Double {
        guard !reduceTransparency,
              !differentiateWithoutColor,
              !isHovered,
              !isKeyboardFocused else { return 1 }
        return FollowUpTilePresentation.baseOpacity(for: commitment.priorityScore)
    }

    private func openDetails() {
        clearPointerEmphasis()
        onOpen()
    }

    private func clearPointerEmphasis() {
        isHovered = false
        isKeyboardFocused = false
    }

    private var subjectChip: some View {
        HStack(spacing: 5) {
            Circle().fill(subject.color.color).frame(width: 7, height: 7)
            Text(subject.name)
                .lineLimit(1)
            Image(systemName: type.systemImage)
                .imageScale(.small)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(subject.color.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(subject.color.color.opacity(0.11), in: Capsule())
    }

    private var scheduleBadges: some View {
        Group {
            if commitment.lifecycle == .snoozed, let returnAt = commitment.snoozedUntil {
                scheduleBadge(
                    snoozeScheduleLabel(returnAt: returnAt),
                    symbol: "moon.zzz",
                    tint: IrizTheme.violet
                )
            } else if let deadline = commitment.explicitDueAt {
                scheduleBadge(
                    "Deadline \(deadline.formatted(date: .abbreviated, time: .shortened))",
                    symbol: "calendar.badge.exclamationmark",
                    tint: deadline < Date() ? .red : subject.color.color
                )
            } else {
                Color.clear
                    .accessibilityHidden(true)
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: FollowUpTilePresentation.scheduleSlotHeight,
            maxHeight: FollowUpTilePresentation.scheduleSlotHeight,
            alignment: .leading
        )
        .clipped()
    }

    private func scheduleBadge(_ text: String, symbol: String, tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(tint.opacity(0.10), in: Capsule())
    }

    private func snoozeScheduleLabel(returnAt: Date) -> String {
        let returnLabel = "Returns \(returnAt.formatted(date: .abbreviated, time: .shortened))"
        guard let snoozedAt = latestSnoozedAt else { return returnLabel }
        return "\(returnLabel) · snoozed \(snoozedAt.formatted(date: .abbreviated, time: .omitted))"
    }

    private var latestSnoozedAt: Date? {
        commitment.history
            .filter { $0.kind == .snoozed }
            .map(\.occurredAt)
            .max()
    }

    private var priorityControl: some View {
        HStack(spacing: 3) {
            Image(systemName: "flag.fill")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .help("Priority")
                .accessibilityLabel("Priority")
            priorityButton(symbol: "minus", delta: -1, disabled: commitment.priorityScore == 0)
            Text("\(commitment.priorityScore)")
                .font(.system(.callout, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .frame(minWidth: 20)
                .contentTransition(.numericText())
            priorityButton(symbol: "plus", delta: 1, disabled: commitment.priorityScore == 10)
        }
        .padding(.leading, 7)
        .padding(.trailing, 2)
        .padding(.vertical, 2)
        .foregroundStyle(.white)
        .background(priorityBackground, in: Capsule())
        .accessibilityElement(children: .contain)
    }

    private func priorityButton(symbol: String, delta: Int, disabled: Bool) -> some View {
        Button {
            isKeyboardFocused = false
            changePriority(by: delta)
        } label: {
            Image(systemName: symbol)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 23, height: 23)
                .background(Color.white.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled || isUpdatingPriority)
        .help(delta < 0 ? "Decrease priority" : "Increase priority")
        .accessibilityLabel(delta < 0 ? "Decrease priority" : "Increase priority")
    }

    private func changePriority(by delta: Int) {
        guard !isUpdatingPriority else { return }
        let score = min(max(commitment.priorityScore + delta, 0), 10)
        guard score != commitment.priorityScore else { return }
        isUpdatingPriority = true
        Task {
            await app.setFollowUpPriority(commitment, score: score)
            isUpdatingPriority = false
        }
    }

    private var priorityBackground: LinearGradient {
        switch FollowUpTilePresentation.priorityBand(for: commitment.priorityScore) {
        case .critical:
            LinearGradient(
                colors: [Color.red.opacity(0.86), IrizTheme.coral.opacity(0.82)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .elevated:
            LinearGradient(
                colors: [IrizTheme.coral.opacity(0.82), Color.orange.opacity(0.76)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .standard:
            LinearGradient(
                colors: [Color.black.opacity(0.16), Color.black.opacity(0.16)],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    private var quickActions: some View {
        HStack(spacing: 7) {
            if commitment.lifecycle == .dismissed {
                Button {
                    clearPointerEmphasis()
                    Task { await app.restoreFollowUp(commitment) }
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.borderedProminent)
                .tint(IrizTheme.violet)
            } else {
                Button {
                    clearPointerEmphasis()
                    Task { await app.completeFollowUp(commitment) }
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(completionButtonFill, in: Circle())
                        .overlay(Circle().stroke(.white.opacity(completionButtonStyle == .suggestedByIriz ? 0.34 : 0.20)))
                        .shadow(
                            color: completionButtonStyle == .suggestedByIriz
                                ? IrizTheme.listening.opacity(0.42)
                                : IrizTheme.mint.opacity(0.26),
                            radius: completionButtonStyle == .suggestedByIriz ? 8 : 6,
                            y: 2
                        )
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
                .help(completionButtonHelp)
                .accessibilityLabel("Mark as done")
                .accessibilityValue(completionButtonStyle == .suggestedByIriz ? "Suggested by iriz" : "")

                Menu {
                    Button("Tomorrow") {
                        clearPointerEmphasis()
                        Task { await app.snoozeCommitment(commitment, days: 1) }
                    }
                    Button("Next week") {
                        clearPointerEmphasis()
                        Task { await app.snoozeCommitment(commitment, days: 7) }
                    }
                    Button("Choose date…") {
                        clearPointerEmphasis()
                        onCustomSnooze()
                    }
                } label: {
                    Image(systemName: "moon.zzz")
                }
                .menuStyle(.borderlessButton)
                .help("Snooze")

                Button {
                    clearPointerEmphasis()
                    Task { await app.dismissFollowUp(commitment) }
                } label: {
                    Image(systemName: "eye.slash")
                }
                .buttonStyle(.bordered)
                .help("Dismiss")
            }

        }
        .controlSize(.small)
    }

    private var exportMenu: some View {
        Menu {
            Button("Add to Reminders") {
                clearPointerEmphasis()
                Task { await app.addFollowUpToReminders(commitment) }
            }
            Button("Copy") {
                clearPointerEmphasis()
                app.copyFollowUp(commitment)
            }
            Divider()
            Button("Open details", action: openDetails)
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.callout.weight(.semibold))
                .frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Share or export")
    }

    private var completionButtonStyle: FollowUpCompletionButtonStyle {
        FollowUpTilePresentation.completionButtonStyle(for: commitment)
    }

    private var completionButtonFill: AnyShapeStyle {
        switch completionButtonStyle {
        case .standard:
            AnyShapeStyle(IrizTheme.mint)
        case .suggestedByIriz:
            AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color(red: 0.10, green: 0.62, blue: 0.40),
                        Color(red: 0.24, green: 0.86, blue: 0.58),
                        Color(red: 0.20, green: 0.74, blue: 0.78)
                    ],
                    startPoint: .bottomLeading,
                    endPoint: .topTrailing
                )
            )
        }
    }

    private var completionButtonHelp: String {
        switch completionButtonStyle {
        case .standard:
            "Mark as done"
        case .suggestedByIriz:
            "iriz found evidence that this may be done"
        }
    }
}

private struct CompletedFollowUpCard: View {
    @EnvironmentObject private var app: AppState
    let commitment: Commitment
    let subject: FollowUpSubject
    let compact: Bool
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Circle().fill(subject.color.color).frame(width: 7, height: 7)
                        Text(subject.name)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(subject.color.color)
                        Spacer()
                        Text((commitment.completedAt ?? commitment.updatedAt).formatted(.relative(presentation: .named)))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text(commitment.action)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(compact ? 2 : 3)
                        .multilineTextAlignment(.leading)
                    Label(
                        commitment.completionActor?.displayName ?? "Completed",
                        systemImage: commitment.completionActor == .iriz ? "sparkles" : "person.fill.checkmark"
                    )
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(IrizTheme.mint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            Button("Reopen") { Task { await app.reopenFollowUp(commitment) } }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(12)
        .background {
            FollowUpTileBackground(subjectColor: subject.color.color)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(subject.color.color.opacity(0.30), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
    }
}

private struct NewFollowUpSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    let completion: (UUID?) -> Void
    @State private var action = ""
    @State private var details = ""
    @State private var subjectID: String?
    @State private var priority = 5
    @State private var hasDueDate = false
    @State private var dueAt = Date().addingTimeInterval(86_400)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add an Action").font(.title2.weight(.bold))
                    Text("iriz usually creates Actions automatically. Add one yourself when needed.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { completion(nil); dismiss() }
                Button("Create") {
                    Task {
                        let id = await app.createManualFollowUp(
                            action: action,
                            details: details,
                            subjectID: subjectID,
                            priority: priority,
                            dueAt: hasDueDate ? dueAt : nil
                        )
                        completion(id)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(IrizTheme.violet)
                .disabled(action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Form {
                TextField("Action", text: $action, axis: .vertical)
                    .lineLimit(2...6)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Notes", text: $details, axis: .vertical)
                    .lineLimit(3...7)
                Picker("Subject", selection: $subjectID) {
                    Text("Uncategorized").tag(String?.none)
                    ForEach(app.followUpSubjects.filter { !FollowUpContextGrouper.isGenericSubjectName($0.name) }) { subject in
                        Text(subject.name).tag(String?.some(subject.id))
                    }
                }
                HStack {
                    Text("Priority")
                    Slider(value: Binding(get: { Double(priority) }, set: { priority = Int($0.rounded()) }), in: 0...10, step: 1)
                    Text("\(priority)/10").monospacedDigit()
                }
                Toggle("Add a due date", isOn: $hasDueDate)
                if hasDueDate { DatePicker("Due", selection: $dueAt) }
            }
            .formStyle(.grouped)
        }
        .padding(22)
        .frame(width: 620, height: 540)
    }
}

private struct CustomSnoozeSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    let commitment: Commitment
    let completion: () -> Void
    @State private var date = Date().addingTimeInterval(86_400)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Snooze Action").font(.title2.weight(.bold))
            Text(commitment.action).foregroundStyle(.secondary)
            DatePicker("Return", selection: $date, in: Date()...)
            HStack {
                Spacer()
                Button("Cancel") { completion(); dismiss() }
                Button("Snooze") {
                    Task {
                        await app.snoozeFollowUp(commitment, until: date)
                        completion()
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(IrizTheme.violet)
            }
        }
        .padding(22)
        .frame(width: 420)
    }
}

private struct FollowUpSubjectManager: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var newTypeID = FollowUpType.uncategorizedID

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Subjects").font(.title2.weight(.bold))
                    Text("Use specific clients, projects, or activities, then assign each one a type.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
            Divider()
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(app.followUpSubjects.filter { !FollowUpContextGrouper.isGenericSubjectName($0.name) }) { subject in
                        SubjectEditorRow(subject: subject)
                    }
                }
                .padding(18)
            }
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    TextField("Client, project, or activity", text: $newName)
                        .textFieldStyle(.roundedBorder)
                    Picker("Type", selection: $newTypeID) {
                        ForEach(app.followUpTypes) { type in Text(type.name).tag(type.id) }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    Button("Add") {
                        let type = app.followUpTypes.first(where: { $0.id == newTypeID })
                            ?? FollowUpType.defaults.last!
                        let subject = FollowUpSubject(name: newName, area: type.area, typeID: type.id)
                        Task { await app.saveFollowUpSubject(subject) }
                        newName = ""
                        newTypeID = FollowUpType.uncategorizedID
                    }
                    .disabled(!canCreateSubject)
                }
                if !newName.isEmpty && FollowUpContextGrouper.isGenericSubjectName(newName) {
                    Text("Choose a concrete subject such as Client Acme, Website Project, or Kids Activities.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(18)
        }
        .frame(width: 680, height: 600)
    }

    private var canCreateSubject: Bool {
        !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !FollowUpContextGrouper.isGenericSubjectName(newName)
            && !app.followUpSubjects.contains {
                $0.name.localizedCaseInsensitiveCompare(newName.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
            }
    }
}

private struct SubjectEditorRow: View {
    @EnvironmentObject private var app: AppState
    let subject: FollowUpSubject
    @State private var draft: FollowUpSubject

    init(subject: FollowUpSubject) {
        self.subject = subject
        _draft = State(initialValue: subject)
    }

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(FollowUpColorToken.allCases) { token in
                    Button(token.rawValue.capitalized) {
                        draft.color = token
                        save()
                    }
                }
            } label: {
                Circle().fill(draft.color.color).frame(width: 18, height: 18)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            TextField("Client, project, or activity", text: $draft.name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            Picker("Type", selection: Binding(
                get: { draft.typeID ?? FollowUpType.defaultID(for: draft.area) },
                set: { identifier in
                    draft.typeID = identifier
                    if let type = app.followUpTypes.first(where: { $0.id == identifier }) {
                        draft.area = type.area
                    }
                    save()
                }
            )) {
                ForEach(app.followUpTypes) { type in Text(type.name).tag(type.id) }
            }
            .labelsHidden()
            .frame(width: 140)
            Text("Bias \(draft.priorityBias, format: .number.precision(.fractionLength(1)))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 58)
            Menu("Merge") {
                ForEach(app.followUpSubjects.filter {
                    $0.id != subject.id && !FollowUpContextGrouper.isGenericSubjectName($0.name)
                }) { target in
                    Button("Into \(target.name)") {
                        Task { await app.mergeSubjects(sourceID: subject.id, into: target.id) }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button {
                Task { await app.mergeAllActiveFollowUps(in: subject.id) }
            } label: {
                Image(systemName: "square.stack.3d.up")
            }
            .buttonStyle(.bordered)
            .help("Merge all active Actions in this subject")
        }
        .padding(12)
        .background(IrizTheme.card.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
    }

    private func save() {
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.name.isEmpty,
              !FollowUpContextGrouper.isGenericSubjectName(draft.name),
              !app.followUpSubjects.contains(where: {
                  $0.id != subject.id && $0.name.localizedCaseInsensitiveCompare(draft.name) == .orderedSame
              }) else { return }
        draft.updatedAt = Date()
        Task { await app.saveFollowUpSubject(draft) }
    }
}

private struct FollowUpTypeManager: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var newArea: FollowUpArea = .uncategorized
    @State private var newColor: FollowUpColorToken = .violet

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Types").font(.title2.weight(.bold))
                    Text("Create broad groupings for subjects, such as Client, Project, Family, or Administration.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
            Divider()
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(app.followUpTypes) { type in
                        FollowUpTypeEditorRow(type: type)
                    }
                }
                .padding(18)
            }
            Divider()
            HStack(spacing: 10) {
                Menu {
                    ForEach(FollowUpColorToken.allCases) { token in
                        Button(token.rawValue.capitalized) { newColor = token }
                    }
                } label: {
                    Circle().fill(newColor.color).frame(width: 18, height: 18)
                }
                .menuStyle(.borderlessButton)
                TextField("New type", text: $newName)
                    .textFieldStyle(.roundedBorder)
                Picker("Internal category", selection: $newArea) {
                    ForEach(FollowUpArea.allCases) { area in Text(area.displayName).tag(area) }
                }
                .labelsHidden()
                .frame(width: 160)
                Button("Add") {
                    let type = FollowUpType(name: newName, area: newArea, color: newColor)
                    Task { await app.saveFollowUpType(type) }
                    newName = ""
                    newArea = .uncategorized
                    newColor = .violet
                }
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(18)
        }
        .frame(width: 700, height: 600)
    }
}

private struct FollowUpTypeEditorRow: View {
    @EnvironmentObject private var app: AppState
    let type: FollowUpType
    @State private var draft: FollowUpType

    private let icons = [
        "briefcase.fill", "person.fill", "folder.fill", "building.2.fill",
        "globe", "house.fill", "figure.2.and.child.holdinghands", "tray.full.fill"
    ]

    init(type: FollowUpType) {
        self.type = type
        _draft = State(initialValue: type)
    }

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(FollowUpColorToken.allCases) { token in
                    Button(token.rawValue.capitalized) {
                        draft.color = token
                        save()
                    }
                }
            } label: {
                Circle().fill(draft.color.color).frame(width: 18, height: 18)
            }
            .menuStyle(.borderlessButton)

            Menu {
                ForEach(icons, id: \.self) { icon in
                    Button { draft.systemImage = icon; save() } label: {
                        Label(icon, systemImage: icon)
                    }
                }
            } label: {
                Image(systemName: draft.systemImage).frame(width: 22)
            }
            .menuStyle(.borderlessButton)

            TextField("Type name", text: $draft.name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)

            Picker("Internal category", selection: $draft.area) {
                ForEach(FollowUpArea.allCases) { area in Text(area.displayName).tag(area) }
            }
            .labelsHidden()
            .frame(width: 150)
            .onChange(of: draft.area) { _, _ in save() }

            if type.isBuiltIn {
                Text("Built in")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 58)
            } else {
                Button(role: .destructive) {
                    Task { await app.deleteFollowUpType(type) }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(app.followUpSubjects.contains(where: { $0.typeID == type.id }))
                .help("Move this type's subjects before deleting it")
            }
        }
        .padding(12)
        .background(IrizTheme.card.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
    }

    private func save() {
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.name.isEmpty else { return }
        draft.updatedAt = Date()
        Task { await app.saveFollowUpType(draft) }
    }
}
