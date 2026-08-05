@preconcurrency import AppKit
import AVFoundation
import SwiftUI

/// A focused, self-contained editor for one follow-up.
///
/// The surrounding view owns presentation and passes `onClose`; the editor keeps
/// itself synchronized with `AppState` while preserving in-progress text edits.
struct FollowUpDetailView: View {
    @EnvironmentObject private var app: AppState

    private let commitmentID: UUID
    private let onClose: () -> Void
    private let onMerge: ((Commitment) -> Void)?

    @State private var draft: Commitment
    @State private var selectedTab: DetailTab?
    @State private var pendingTextFields: Set<FollowUpEditableField> = []
    @State private var textSaveTask: Task<Void, Never>?
    @State private var localError: String?
    @State private var isChoosingSnoozeDate = false
    @State private var customSnoozeDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var previewData: [String: Data] = [:]
    @State private var loadingMedia: Set<String> = []
    @State private var unavailableMedia: Set<String> = []
    @State private var audioPlayer: AVAudioPlayer?
    @State private var activeAudioIdentifier: String?
    @FocusState private var titleIsFocused: Bool

    /// Creates a detail editor that can be presented from any Follow Up surface.
    /// `onMerge` can hand off to a custom picker; without it, the built-in merge
    /// menu offers compatible active follow-ups.
    init(
        commitment: Commitment,
        onClose: @escaping () -> Void,
        onMerge: ((Commitment) -> Void)? = nil
    ) {
        commitmentID = commitment.id
        self.onClose = onClose
        self.onMerge = onMerge
        _draft = State(initialValue: commitment)
    }

    var body: some View {
        VStack(spacing: 0) {
            essentialHeader
            Divider()
            actionBar
            Divider()
            tabBar
            if selectedTab != nil {
                Divider()
                tabContent
            }
        }
        .frame(width: 780, height: selectedTab == nil ? 490 : 700)
        .background(detailBackground)
        .animation(.snappy(duration: 0.22), value: selectedTab)
        .onAppear {
            synchronizeDraft()
            clearInitialTextFocus()
        }
        .onChange(of: app.commitments) { _, _ in synchronizeDraft() }
        .onChange(of: app.resolvedCommitments) { _, _ in synchronizeDraft() }
        .onDisappear {
            flushTextEdits()
            releaseMedia()
        }
    }

    // MARK: - Persistent chrome

    private var essentialHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                subjectBadge
                metadataBadge(followUpType.name, symbol: followUpType.systemImage, tint: followUpType.color.color)
                metadataBadge(originLabel, symbol: draft.origin == .manual ? "person.fill" : "sparkles", tint: IrizTheme.violet)
                metadataBadge(lifecycleLabel, symbol: lifecycleSymbol, tint: lifecycleTint)
                Spacer(minLength: 12)
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Close")
                .keyboardShortcut(.cancelAction)
            }

            HStack(alignment: .top, spacing: 10) {
                TextField("Follow-up title", text: actionBinding, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($titleIsFocused)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .lineLimit(2...4)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Follow-up title")
                    .accessibilityAddTraits(.isHeader)
                Image(systemName: "pencil")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(subjectColor)
                    .padding(.top, 5)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(subjectColor.opacity(0.20)))

            VStack(alignment: .leading, spacing: 6) {
                Label("Description", systemImage: "text.alignleft")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextEditor(text: detailsBinding)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(height: 72)
                    .padding(8)
                    .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.08)))
                    .accessibilityLabel("Description")
            }

            HStack(alignment: .bottom, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Subject", systemImage: "tag.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Picker("Subject", selection: subjectBinding) {
                        if draft.subjectID == nil {
                            Text("Uncategorized").tag("")
                        }
                        ForEach(app.followUpSubjects) { subject in
                            Text("\(subject.name) · \(typeName(for: subject))").tag(subject.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Label("Deadline", systemImage: "calendar.badge.exclamationmark")
                        if draft.dueAt != nil {
                            Text("· \(dueSourceLabel)")
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    deadlineControl
                }

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 6) {
                    Label("Priority", systemImage: "flag.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    priorityControl
                }
            }

            if let message = visibleOperationMessage {
                Label(message, systemImage: localError == nil ? "info.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(localError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 16)
    }

    private var actionBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                lifecycleActions
                Divider().frame(height: 22)
                mergeControl
                Button {
                    Task { await app.addFollowUpToReminders(currentCommitment) }
                } label: {
                    Label("Add to Reminders", systemImage: "list.bullet.circle")
                }
                .buttonStyle(.bordered)

                Menu {
                    ShareLink(item: shareText) {
                        Label("Share…", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        app.copyFollowUp(currentCommitment)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder private var lifecycleActions: some View {
        switch draft.lifecycle {
        case .completed:
            Button {
                Task { await app.reopenFollowUp(currentCommitment) }
            } label: {
                Label("Reopen", systemImage: "arrow.uturn.backward.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(IrizTheme.violet)
        case .dismissed:
            Button {
                Task { await app.restoreFollowUp(currentCommitment) }
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(IrizTheme.violet)
        case .active, .snoozed:
            if draft.lifecycle == .snoozed {
                Button {
                    Task { await app.restoreFollowUp(currentCommitment) }
                } label: {
                    Label("Restore Now", systemImage: "sun.max")
                }
                .buttonStyle(.bordered)
            }
            Button {
                Task { await app.completeFollowUp(currentCommitment) }
            } label: {
                Label("Done", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .tint(IrizTheme.mint)

            Menu {
                Button("Tomorrow") { snooze(days: 1) }
                Button("Next Week") { snooze(days: 7) }
                Divider()
                Button("Choose Date…") { isChoosingSnoozeDate = true }
            } label: {
                Label("Snooze", systemImage: "clock")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .popover(isPresented: $isChoosingSnoozeDate, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Snooze until").font(.headline)
                    DatePicker(
                        "Return date",
                        selection: $customSnoozeDate,
                        in: Date()...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .labelsHidden()
                    HStack {
                        Spacer()
                        Button("Cancel") { isChoosingSnoozeDate = false }
                        Button("Snooze") {
                            let date = customSnoozeDate
                            isChoosingSnoozeDate = false
                            Task { await app.snoozeFollowUp(currentCommitment, until: date) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(IrizTheme.violet)
                    }
                }
                .padding(18)
                .frame(width: 300)
            }

            Button(role: .destructive) {
                Task { await app.dismissFollowUp(currentCommitment) }
            } label: {
                Label("Dismiss", systemImage: "xmark")
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder private var mergeControl: some View {
        if let onMerge {
            Button {
                onMerge(currentCommitment)
            } label: {
                Label("Merge", systemImage: "arrow.triangle.merge")
            }
            .buttonStyle(.bordered)
            .disabled(draft.lifecycle != .active)
        } else {
            Menu {
                if mergeCandidates.isEmpty {
                    Text("No compatible active follow-ups")
                } else {
                    Section("Merge with") {
                        ForEach(mergeCandidates.prefix(12)) { candidate in
                            Button(candidate.action) {
                                Task {
                                    await app.mergeFollowUps(
                                        ids: [commitmentID, candidate.id],
                                        targetID: commitmentID
                                    )
                                }
                            }
                        }
                    }
                    if let subjectID = draft.subjectID,
                       activeCommitments(in: subjectID).count > 2 {
                        Divider()
                        Button("Merge All in This Subject") {
                            let ids = activeCommitments(in: subjectID).map(\.id)
                            Task { await app.mergeFollowUps(ids: ids, targetID: commitmentID) }
                        }
                    }
                }
            } label: {
                Label("Merge", systemImage: "arrow.triangle.merge")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(draft.lifecycle != .active || mergeCandidates.isEmpty)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 8) {
            ForEach(DetailTab.allCases) { tab in
                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        selectedTab = selectedTab == tab ? nil : tab
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: tab.symbol)
                        Text(tab.title)
                        Image(systemName: selectedTab == tab ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(
                        selectedTab == tab ? subjectColor.opacity(0.18) : Color.primary.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(selectedTab == tab ? subjectColor.opacity(0.42) : .clear)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityValue(selectedTab == tab ? "Expanded" : "Collapsed")
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var tabContent: some View {
        if let selectedTab {
            switch selectedTab {
            case .details: detailsTab
            case .evidence: evidenceTab
            case .history: historyTab
            }
        }
    }

    // MARK: - Details

    private var detailsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                detailSection("Iriz context", symbol: "sparkles") {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                        informationRow("Displayed priority", "\(draft.priorityScore)/10")
                        informationRow("Iriz priority", "\(draft.aiPriorityScore)/10")
                        if let subject {
                            informationRow("Learned subject adjustment", signed(subject.priorityBias))
                        }
                        informationRow("Priority reason", nonEmpty(draft.priorityReason, fallback: "No explanation recorded"))
                        informationRow("Detection confidence", "\(Int((draft.confidence * 100).rounded()))%")
                        informationRow("Origin", originLabel)
                        informationRow("Created detail level", draft.detailLevelAtCreation.displayName)
                        informationRow("Lifecycle", lifecycleLabel)
                        if draft.dueAt != nil {
                            informationRow("Deadline source", dueSourceLabel)
                            if let confidence = draft.dueConfidence {
                                informationRow("Deadline confidence", "\(Int((confidence * 100).rounded()))%")
                            }
                        }
                        informationRow("Rationale", nonEmpty(draft.rationale, fallback: "No additional rationale"))
                        if let hint = draft.evidenceHint, !hint.isEmpty {
                            informationRow("Evidence hint", hint)
                        }
                    }
                }

                detailSection("Dates", symbol: "clock.arrow.circlepath") {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                        informationRow("Created", fullDate(draft.createdAt))
                        informationRow("Last updated", fullDate(draft.updatedAt))
                        informationRow("Last surfaced", fullDate(draft.surfacedAt))
                        if let date = latestSnoozedAt { informationRow("Snoozed on", fullDate(date)) }
                        if let date = draft.snoozedUntil { informationRow("Snoozed until", fullDate(date)) }
                        if let date = draft.completedAt { informationRow("Completed", fullDate(date)) }
                        if let date = draft.dismissedAt { informationRow("Dismissed", fullDate(date)) }
                        if !previousExports.isEmpty {
                            informationRow("Previous exports", previousExports)
                        }
                    }
                }
            }
            .padding(22)
        }
    }

    // MARK: - Evidence

    private var evidenceTab: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if let completionEvidence = draft.completionEvidence {
                    completionEvidenceCard(completionEvidence)
                }
                if linkedEvents.isEmpty {
                    ContentUnavailableView(
                        "No linked Journal events",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Structured evidence will appear here when Iriz links activity to this follow-up.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 280)
                } else {
                    ForEach(linkedEvents) { event in
                        eventEvidenceCard(event)
                    }
                }
            }
            .padding(22)
        }
    }

    private func completionEvidenceCard(_ evidence: FollowUpCompletionEvidence) -> some View {
        detailSection("Completion evidence", symbol: "checkmark.seal.fill") {
            VStack(alignment: .leading, spacing: 8) {
                Text(evidence.summary)
                    .textSelection(.enabled)
                HStack(spacing: 12) {
                    Label(evidence.strength.displayName, systemImage: "bolt.shield")
                    Label("\(Int((evidence.confidence * 100).rounded()))% confidence", systemImage: "waveform.path.ecg")
                    Text(fullDate(evidence.capturedAt))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Button("Open in Journal") { app.openEvent(evidence.eventID) }
                    .buttonStyle(.link)
            }
        }
    }

    private func eventEvidenceCard(_ event: ActivityEvent) -> some View {
        detailSection(event.title, symbol: event.kind.symbolName) {
            VStack(alignment: .leading, spacing: 11) {
                if !event.summary.isEmpty {
                    Text(event.summary).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if !event.details.isEmpty {
                    Text(event.details).font(.callout).textSelection(.enabled)
                }
                HStack(spacing: 12) {
                    Label(fullDate(event.startedAt), systemImage: "clock")
                    Label("\(Int((event.confidence * 100).rounded()))% confidence", systemImage: "waveform.path.ecg")
                    if !event.sourceApplications.isEmpty {
                        Label(event.sourceApplications.joined(separator: ", "), systemImage: "app")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                ForEach(event.urls, id: \.absoluteString) { url in
                    Link(destination: url) {
                        Label(url.absoluteString, systemImage: "arrow.up.right.square")
                            .lineLimit(1)
                    }
                    .font(.caption)
                }

                ForEach(event.evidence) { reference in
                    Divider()
                    evidenceReference(reference)
                }

                Button {
                    app.openEvent(event.id)
                } label: {
                    Label("Open in Journal", systemImage: "arrow.up.forward.square")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func evidenceReference(_ reference: EvidenceReference) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(reference.source.displayName, systemImage: reference.source.symbol)
                    .font(.caption.weight(.semibold))
                Text(fullDate(reference.capturedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                mediaPreviewButton(reference)
            }
            if let excerpt = reference.excerpt, !excerpt.isEmpty {
                Text(excerpt)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
            }
            mediaPreview(reference)
        }
    }

    @ViewBuilder private func mediaPreviewButton(_ reference: EvidenceReference) -> some View {
        if reference.isExpired {
            Text("Raw media expired")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        } else if let identifier = reference.mediaIdentifier {
            if loadingMedia.contains(identifier) {
                ProgressView().controlSize(.small)
            } else if previewData[identifier] == nil {
                Button("Preview") { loadPreview(reference) }
                    .buttonStyle(.link)
            } else {
                Button("Hide") {
                    stopAudioIfNeeded(identifier)
                    previewData[identifier] = nil
                }
                .buttonStyle(.link)
            }
        }
    }

    @ViewBuilder private func mediaPreview(_ reference: EvidenceReference) -> some View {
        if reference.isExpired {
            Label(
                "The raw media is no longer available after the 24-hour retention window. The structured evidence above remains available.",
                systemImage: "clock.badge.xmark"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if let identifier = reference.mediaIdentifier,
                  unavailableMedia.contains(identifier) {
            Label("The raw media could not be loaded and may have expired.", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let identifier = reference.mediaIdentifier,
                  let data = previewData[identifier] {
            if reference.source == .screen, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.08)))
                    .accessibilityLabel("Captured screen evidence")
            } else if reference.source.isAudio {
                HStack(spacing: 10) {
                    Button {
                        toggleAudio(identifier: identifier, data: data)
                    } label: {
                        Label(
                            audioIsPlaying(identifier) ? "Stop Audio" : "Play Audio",
                            systemImage: audioIsPlaying(identifier) ? "stop.fill" : "play.fill"
                        )
                    }
                    .buttonStyle(.bordered)
                    Text("Decrypted in memory only")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("Media loaded in memory (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))", systemImage: "doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - History

    private var historyTab: some View {
        ScrollView {
            if draft.history.isEmpty {
                ContentUnavailableView(
                    "No history yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Edits, snoozes, exports and lifecycle changes will appear here.")
                )
                .frame(maxWidth: .infinity, minHeight: 320)
                .padding(22)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(draft.history.sorted { $0.occurredAt > $1.occurredAt }) { entry in
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: entry.kind.symbol)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(entry.actor.tint)
                                .frame(width: 30, height: 30)
                                .background(entry.actor.tint.opacity(0.11), in: Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(entry.kind.displayName).font(.callout.weight(.semibold))
                                    Text("· \(entry.actor.displayName)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(fullDate(entry.occurredAt))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(entry.summary)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                if let eventID = entry.eventID {
                                    Button("Open evidence in Journal") { app.openEvent(eventID) }
                                        .buttonStyle(.link)
                                        .font(.caption)
                                }
                            }
                        }
                        .padding(.vertical, 12)
                        if entry.id != draft.history.sorted(by: { $0.occurredAt > $1.occurredAt }).last?.id {
                            Divider().padding(.leading, 44)
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: - Bindings and persistence

    private var actionBinding: Binding<String> {
        Binding(get: { draft.action }, set: { value in
            draft.action = value
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { localError = nil }
            queueTextSave(.action)
        })
    }

    private var detailsBinding: Binding<String> {
        Binding(get: { draft.details }, set: { value in
            draft.details = value
            queueTextSave(.details)
        })
    }

    private var subjectBinding: Binding<String> {
        Binding(get: { draft.subjectID ?? "" }, set: { subjectID in
            guard !subjectID.isEmpty,
                  let selected = app.followUpSubjects.first(where: { $0.id == subjectID }) else { return }
            draft.subjectID = selected.id
            draft.contextLabel = selected.name
            draft.area = selected.area
            Task { await app.assignFollowUp(currentCommitment, to: selected.id) }
        })
    }

    private var dueDateBinding: Binding<Date> {
        Binding(get: { draft.dueAt ?? Date() }, set: { value in
            draft.explicitDueAt = value
            draft.suggestedReviewAt = nil
            saveMetadata(fields: [.dueDate])
        })
    }

    private func queueTextSave(_ field: FollowUpEditableField) {
        pendingTextFields.insert(field)
        textSaveTask?.cancel()
        textSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await savePendingTextEdits()
        }
    }

    private func savePendingTextEdits() async {
        var fields = pendingTextFields
        if fields.contains(.action), draft.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fields.remove(.action)
            localError = "The action title cannot be empty."
        }
        guard !fields.isEmpty else { return }
        pendingTextFields.subtract(fields)
        await app.saveEditedFollowUp(draft, fields: fields)
    }

    private func flushTextEdits() {
        textSaveTask?.cancel()
        var fields = pendingTextFields
        if fields.contains(.action), draft.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fields.remove(.action)
        }
        guard !fields.isEmpty else { return }
        let snapshot = draft
        pendingTextFields.subtract(fields)
        Task { await app.saveEditedFollowUp(snapshot, fields: fields) }
    }

    private func saveMetadata(fields: Set<FollowUpEditableField>) {
        let snapshot = draft
        Task { await app.saveEditedFollowUp(snapshot, fields: fields) }
    }

    private func changePriority(by delta: Int) {
        let score = min(max(draft.priorityScore + delta, 0), 10)
        guard score != draft.priorityScore else { return }
        draft.userPriorityScore = score
        Task { await app.setFollowUpPriority(currentCommitment, score: score) }
    }

    private func addDeadline() {
        draft.explicitDueAt = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        draft.suggestedReviewAt = nil
        draft.dueSource = .user
        draft.dueConfidence = 1
        saveMetadata(fields: [.dueDate])
    }

    private func removeDeadline() {
        draft.explicitDueAt = nil
        draft.suggestedReviewAt = nil
        draft.dueSource = nil
        draft.dueConfidence = nil
        saveMetadata(fields: [.dueDate])
    }

    private func synchronizeDraft() {
        guard pendingTextFields.isEmpty,
              let value = liveCommitment else { return }
        draft = value
    }

    private func clearInitialTextFocus() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            titleIsFocused = false
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    private func close() {
        flushTextEdits()
        releaseMedia()
        onClose()
    }

    // MARK: - Media

    private func loadPreview(_ reference: EvidenceReference) {
        guard !reference.isExpired, let identifier = reference.mediaIdentifier else { return }
        loadingMedia.insert(identifier)
        unavailableMedia.remove(identifier)
        Task { @MainActor in
            let data = await app.mediaData(identifier: identifier)
            loadingMedia.remove(identifier)
            if let data {
                previewData[identifier] = data
            } else {
                unavailableMedia.insert(identifier)
            }
        }
    }

    private func toggleAudio(identifier: String, data: Data) {
        if activeAudioIdentifier == identifier, audioPlayer?.isPlaying == true {
            audioPlayer?.stop()
            activeAudioIdentifier = nil
            return
        }
        audioPlayer?.stop()
        guard let player = try? AVAudioPlayer(data: data) else {
            unavailableMedia.insert(identifier)
            previewData[identifier] = nil
            return
        }
        player.prepareToPlay()
        player.play()
        audioPlayer = player
        activeAudioIdentifier = identifier
    }

    private func stopAudioIfNeeded(_ identifier: String) {
        guard activeAudioIdentifier == identifier else { return }
        audioPlayer?.stop()
        audioPlayer = nil
        activeAudioIdentifier = nil
    }

    private func audioIsPlaying(_ identifier: String) -> Bool {
        activeAudioIdentifier == identifier && audioPlayer?.isPlaying == true
    }

    private func releaseMedia() {
        audioPlayer?.stop()
        audioPlayer = nil
        activeAudioIdentifier = nil
        previewData.removeAll()
        unavailableMedia.removeAll()
        loadingMedia.removeAll()
    }

    // MARK: - Derived values and reusable UI

    private var liveCommitment: Commitment? {
        (app.commitments + app.resolvedCommitments).first(where: { $0.id == commitmentID })
    }

    private var currentCommitment: Commitment { draft }

    private var subject: FollowUpSubject? {
        draft.subjectID.flatMap { id in app.followUpSubjects.first(where: { $0.id == id }) }
    }

    private var subjectColor: Color { subject?.color.color ?? IrizTheme.violet }

    private var detailBackground: some View {
        ZStack {
            IrizTheme.canvas
            LinearGradient(
                colors: [subjectColor.opacity(0.18), subjectColor.opacity(0.07), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var followUpType: FollowUpType {
        let identifier = subject?.typeID ?? FollowUpType.defaultID(for: draft.area)
        return app.followUpTypes.first(where: { $0.id == identifier })
            ?? FollowUpType.defaults.first(where: { $0.id == FollowUpType.defaultID(for: draft.area) })!
    }

    private func typeName(for subject: FollowUpSubject) -> String {
        let identifier = subject.typeID ?? FollowUpType.defaultID(for: subject.area)
        return app.followUpTypes.first(where: { $0.id == identifier })?.name ?? subject.area.displayName
    }

    private var subjectBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(subjectColor).frame(width: 8, height: 8)
            Text(subject?.name ?? draft.contextLabel ?? "Uncategorized")
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(subjectColor.opacity(0.12), in: Capsule())
        .foregroundStyle(subjectColor)
    }

    @ViewBuilder private var deadlineControl: some View {
        if draft.dueAt != nil {
            HStack(spacing: 6) {
                DatePicker(
                    "Deadline",
                    selection: dueDateBinding,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .labelsHidden()
                .frame(width: 180)
                .tint(dueTint)

                Button {
                    removeDeadline()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Remove deadline")
                .accessibilityLabel("Remove deadline")
            }
        } else {
            Button {
                addDeadline()
            } label: {
                Label("Add deadline", systemImage: "calendar.badge.plus")
                    .frame(minWidth: 126)
            }
            .buttonStyle(.bordered)
        }
    }

    private var priorityControl: some View {
        HStack(spacing: 3) {
            Image(systemName: "flag.fill")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .accessibilityLabel("Priority")
            detailPriorityButton(symbol: "minus", delta: -1, disabled: draft.priorityScore == 0)
            Text("\(draft.priorityScore)")
                .font(.system(.callout, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .frame(minWidth: 20)
                .contentTransition(.numericText())
            detailPriorityButton(symbol: "plus", delta: 1, disabled: draft.priorityScore == 10)
        }
        .padding(.leading, 7)
        .padding(.trailing, 2)
        .padding(.vertical, 2)
        .background(priorityBackground, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Priority \(draft.priorityScore) out of 10")
    }

    private func detailPriorityButton(symbol: String, delta: Int, disabled: Bool) -> some View {
        Button {
            changePriority(by: delta)
        } label: {
            Image(systemName: symbol)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 23, height: 23)
                .background(Color.white.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(delta < 0 ? "Decrease priority" : "Increase priority")
        .accessibilityLabel(delta < 0 ? "Decrease priority" : "Increase priority")
    }

    private var priorityBackground: LinearGradient {
        switch FollowUpTilePresentation.priorityBand(for: draft.priorityScore) {
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

    private func metadataBadge(_ text: String, symbol: String, tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(tint.opacity(0.09), in: Capsule())
    }

    private func detailSection<Content: View>(
        _ title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(IrizTheme.violet)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IrizTheme.card.opacity(0.72), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.06)))
    }

    private func informationRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .gridColumnAlignment(.leading)
        }
    }

    private var linkedEvents: [ActivityEvent] {
        var ids = Set([draft.eventID] + draft.linkedEventIDs)
        if let id = draft.completionEvidence?.eventID { ids.insert(id) }
        for id in draft.history.compactMap(\.eventID) { ids.insert(id) }
        return app.events
            .filter { ids.contains($0.id) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private var latestSnoozedAt: Date? {
        draft.history
            .filter { $0.kind == .snoozed }
            .map(\.occurredAt)
            .max()
    }

    private var mergeCandidates: [Commitment] {
        app.commitments
            .filter { $0.id != commitmentID && $0.lifecycle == .active }
            .sorted {
                let lhsMatches = $0.subjectID == draft.subjectID
                let rhsMatches = $1.subjectID == draft.subjectID
                if lhsMatches != rhsMatches { return lhsMatches }
                return $0.surfacedAt > $1.surfacedAt
            }
    }

    private func activeCommitments(in subjectID: String) -> [Commitment] {
        app.commitments.filter { $0.lifecycle == .active && $0.subjectID == subjectID }
    }

    private func snooze(days: Int) {
        guard let date = Calendar.current.date(byAdding: .day, value: days, to: Date()) else { return }
        Task { await app.snoozeFollowUp(currentCommitment, until: date) }
    }

    private var shareText: String {
        FollowUpExportService.plainText(for: app.exportPayload(for: currentCommitment))
    }

    private var visibleOperationMessage: String? { localError ?? app.followUpOperationMessage }
    private var previousExports: String {
        draft.history
            .filter { $0.kind == .exported }
            .sorted { $0.occurredAt > $1.occurredAt }
            .map { "\($0.summary) · \(fullDate($0.occurredAt))" }
            .joined(separator: "\n")
    }
    private var originLabel: String { draft.origin == .manual ? "Created by you" : "Created by Iriz" }

    private var lifecycleLabel: String {
        switch draft.lifecycle {
        case .active: "Active"
        case .snoozed: "Snoozed"
        case .completed: draft.completionActor?.displayName ?? "Completed"
        case .dismissed: "Dismissed"
        }
    }

    private var lifecycleSymbol: String {
        switch draft.lifecycle {
        case .active: "circle.fill"
        case .snoozed: "clock.fill"
        case .completed: "checkmark.circle.fill"
        case .dismissed: "xmark.circle.fill"
        }
    }

    private var lifecycleTint: Color {
        switch draft.lifecycle {
        case .active: IrizTheme.observing
        case .snoozed: IrizTheme.processing
        case .completed: IrizTheme.mint
        case .dismissed: .secondary
        }
    }

    private var dueSourceLabel: String {
        switch draft.dueSource {
        case .explicitEvidence: "Explicit in evidence"
        case .inferredByIriz: "Legacy estimate — not a deadline"
        case .user: "Set by you"
        case nil: "Deadline source unknown"
        }
    }

    private var dueTint: Color {
        guard let due = draft.dueAt else { return .secondary }
        return due < Date() ? .red : (due.timeIntervalSinceNow < 86_400 ? IrizTheme.attention : IrizTheme.violet)
    }

    private func fullDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private func signed(_ value: Double) -> String {
        String(format: value >= 0 ? "+%.2f" : "%.2f", value)
    }

    private func nonEmpty(_ value: String, fallback: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : value
    }
}

private enum DetailTab: String, CaseIterable, Identifiable {
    case details
    case evidence
    case history

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .details: "text.alignleft"
        case .evidence: "doc.text.magnifyingglass"
        case .history: "clock.arrow.circlepath"
        }
    }
}

private extension EvidenceReference {
    var isExpired: Bool { expiresAt.map { $0 <= Date() } == true }
}

private extension ObservationSource {
    var displayName: String {
        switch self {
        case .screen: "Screen capture"
        case .ambientAudio: "Ambient audio"
        case .meetingMicrophone: "Meeting microphone"
        case .meetingSystemAudio: "Meeting system audio"
        case .manualNote: "Manual note"
        }
    }

    var symbol: String {
        switch self {
        case .screen: "rectangle.inset.filled"
        case .ambientAudio: "waveform"
        case .meetingMicrophone: "mic.fill"
        case .meetingSystemAudio: "speaker.wave.2.fill"
        case .manualNote: "note.text"
        }
    }

    var isAudio: Bool {
        switch self {
        case .ambientAudio, .meetingMicrophone, .meetingSystemAudio: true
        case .screen, .manualNote: false
        }
    }
}

private extension FollowUpEvidenceStrength {
    var displayName: String {
        switch self {
        case .weak: "Weak evidence"
        case .strong: "Strong evidence"
        case .explicit: "Explicit evidence"
        }
    }
}

private extension FollowUpHistoryKind {
    var displayName: String {
        switch self {
        case .created: "Created"
        case .edited: "Edited"
        case .prioritized: "Priority changed"
        case .snoozed: "Snoozed"
        case .resurfaced: "Resurfaced"
        case .completed: "Completed"
        case .reopened: "Reopened"
        case .dismissed: "Dismissed"
        case .restored: "Restored"
        case .evidence: "Evidence added"
        case .merged: "Merged"
        case .exported: "Exported"
        }
    }

    var symbol: String {
        switch self {
        case .created: "plus.circle.fill"
        case .edited: "pencil.circle.fill"
        case .prioritized: "arrow.up.circle.fill"
        case .snoozed: "clock.fill"
        case .resurfaced: "sun.max.fill"
        case .completed: "checkmark.circle.fill"
        case .reopened: "arrow.uturn.backward.circle.fill"
        case .dismissed: "xmark.circle.fill"
        case .restored: "arrow.uturn.forward.circle.fill"
        case .evidence: "doc.badge.plus"
        case .merged: "arrow.triangle.merge"
        case .exported: "square.and.arrow.up.circle.fill"
        }
    }
}

private extension FollowUpHistoryActor {
    var displayName: String {
        switch self {
        case .user: "You"
        case .iriz: "Iriz"
        case .system: "System"
        }
    }

    var tint: Color {
        switch self {
        case .user: IrizTheme.observing
        case .iriz: IrizTheme.violet
        case .system: .secondary
        }
    }
}
