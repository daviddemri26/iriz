import SwiftUI

enum ObservationControlMetrics {
    static let cardWidth: CGFloat = 276
    static let cardHeight: CGFloat = 313
    static let indicatorTopProtrusion: CGFloat = 22
    static let indicatorLeadingProtrusion: CGFloat = 6
    static let floatingWidth: CGFloat = cardWidth + indicatorLeadingProtrusion
    static let floatingHeight: CGFloat = cardHeight + indicatorTopProtrusion
    static let sidebarWidth: CGFloat = cardWidth + 24
}

enum IndicatorSettingsDestination {
    static func category(for captureHealth: CaptureHealth) -> SettingsCategory? {
        if case .permissionNeeded = captureHealth { return .privacy }
        return nil
    }
}

struct ObservationChannelsControl: View {
    enum Presentation {
        case compact
        case settings
    }

    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var settings: SettingsStore
    var presentation: Presentation = .compact

    var body: some View {
        HStack(spacing: presentation == .compact ? 6 : 10) {
            channelButton(
                title: "Observe",
                detail: channelDetail(
                    isSelected: app.isObserveEnabled,
                    isActive: settings.settings.isScreenCaptureActiveNow && channelsCanBeActiveNow,
                    source: "Screen"
                ),
                symbol: "eye.fill",
                tint: IrizTheme.observing,
                isSelected: app.isObserveEnabled,
                isActive: settings.settings.isScreenCaptureActiveNow && channelsCanBeActiveNow
            ) {
                app.setObserveEnabled(!app.isObserveEnabled)
            }
            channelButton(
                title: "Listen",
                detail: channelDetail(
                    isSelected: app.isListenEnabled,
                    isActive: settings.settings.isAudioActiveNow && channelsCanBeActiveNow,
                    source: "Microphone"
                ),
                symbol: "waveform",
                tint: IrizTheme.listening,
                isSelected: app.isListenEnabled,
                isActive: settings.settings.isAudioActiveNow && channelsCanBeActiveNow
            ) {
                app.setListenEnabled(!app.isListenEnabled)
            }
        }
        .opacity(settings.settings.isPaused ? 0.78 : 1)
    }

    private var channelsCanBeActiveNow: Bool {
        switch app.captureHealth {
        case .paused, .waitingForSchedule, .permissionNeeded, .error:
            false
        case .observing, .listening, .observingAndListening, .meeting,
             .meetingAndListening, .processing:
            true
        }
    }

    private func channelButton(
        title: String,
        detail: String,
        symbol: String,
        tint: Color,
        isSelected: Bool,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: presentation == .compact ? 4 : 10) {
                Image(systemName: symbol)
                    .font(.system(size: presentation == .compact ? 11 : 14, weight: .semibold))
                    .foregroundStyle(isActive ? tint : Color.secondary)
                if presentation == .compact {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.callout.weight(.semibold))
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 2)
                if presentation == .settings {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isActive ? tint : Color.secondary)
                }
            }
            .padding(.horizontal, presentation == .compact ? 7 : 12)
            .frame(maxWidth: .infinity, minHeight: presentation == .compact ? 34 : 50)
            .background(
                isActive ? tint.opacity(0.13) : Color.primary.opacity(isSelected ? 0.075 : 0.045),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isActive ? tint.opacity(0.38) : Color.primary.opacity(isSelected ? 0.14 : 0.06))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "On" : "Off")
        .help("Turn \(title.lowercased()) \(isSelected ? "off" : "on")")
    }

    private func channelDetail(isSelected: Bool, isActive: Bool, source: String) -> String {
        guard isSelected else { return "\(source) · Off" }
        if isActive { return "\(source) · Active now" }
        if settings.settings.isPaused { return "\(source) · Ready after Resume" }
        if settings.settings.captureTiming == .schedule { return "\(source) · Waiting for schedule" }
        return "\(source) · Ready"
    }
}

struct ObservationControlCard: View {
    enum Placement: Equatable {
        case sidebar
        case floating
    }

    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var settings: SettingsStore
    @State private var noteText = ""
    @State private var isAddingNote = false

    var placement: Placement = .sidebar
    var dragChanged: (() -> Void)?
    var dragEnded: (() -> Void)?
    var interactionChanged: ((Bool) -> Void)?

    private var appearance: IndicatorPresentation { app.indicatorPresentation }
    private var settingsDestination: SettingsCategory? {
        IndicatorSettingsDestination.category(for: app.captureHealth)
    }
    private var cardXOffset: CGFloat {
        placement == .floating ? ObservationControlMetrics.indicatorLeadingProtrusion : 0
    }
    private var indicatorXOffset: CGFloat {
        placement == .floating ? 0 : -ObservationControlMetrics.indicatorLeadingProtrusion
    }
    private var outerWidth: CGFloat {
        placement == .floating
            ? ObservationControlMetrics.floatingWidth
            : ObservationControlMetrics.cardWidth
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            cardSurface
                .offset(
                    x: cardXOffset,
                    y: ObservationControlMetrics.indicatorTopProtrusion
                )

            detachedIndicator
                .offset(x: indicatorXOffset)
        }
        .frame(
            width: outerWidth,
            height: ObservationControlMetrics.floatingHeight,
            alignment: .topLeading
        )
    }

    @ViewBuilder private var detachedIndicator: some View {
        if placement == .floating {
            detachedIndicatorContent
                .simultaneousGesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { _ in dragChanged?() }
                        .onEnded { _ in dragEnded?() }
                )
        } else {
            detachedIndicatorContent
        }
    }

    private var detachedIndicatorContent: some View {
        StatusGlyph(appearance: appearance)
            .contentShape(
                RoundedRectangle(
                    cornerRadius: IrizIndicatorMetrics.logoSize
                        * IrizIndicatorMetrics.logoCornerRadiusRatio
                        + IrizIndicatorMetrics.ringOutset,
                    style: .continuous
                )
            )
            .onTapGesture {
                if let settingsDestination {
                    app.openSettings(category: settingsDestination)
                }
            }
            .help(settingsDestination == nil ? appearance.title : "Open Privacy settings")
    }

    private var cardSurface: some View {
        VStack(alignment: .leading, spacing: 7) {
            draggableHeader
            navigationActions
            sectionDivider
            captureActionSlot
            sectionDivider
            ObservationChannelsControl(presentation: .compact)
            controlRow
            footer
        }
        .padding(13)
        .frame(
            width: ObservationControlMetrics.cardWidth,
            height: ObservationControlMetrics.cardHeight,
            alignment: .top
        )
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(IrizTheme.card)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(appearance.tint.opacity(appearance.rotates ? 0.075 : 0.04))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(appearance.tint.opacity(0.19))
        }
    }

    @ViewBuilder private var draggableHeader: some View {
        if placement == .floating {
            statusHeader
                .contentShape(Rectangle())
                .simultaneousGesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { _ in dragChanged?() }
                        .onEnded { _ in dragEnded?() }
                )
        } else {
            statusHeader
        }
    }

    @ViewBuilder private var statusHeader: some View {
        if let settingsDestination {
            Button {
                app.openSettings(category: settingsDestination)
            } label: {
                statusHeaderContent
            }
            .buttonStyle(.plain)
            .help("Open Privacy settings")
            .accessibilityHint("Opens the Privacy category in Iriz Settings")
        } else {
            statusHeaderContent
        }
    }

    private var statusHeaderContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Text(appearance.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                    .padding(.leading, 42)
                Spacer(minLength: 4)
                Text(appearance.badge)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(0.6)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(appearance.tint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .frame(minWidth: 54)
                    .background(appearance.tint.opacity(0.12), in: Capsule())
                    .fixedSize(horizontal: true, vertical: false)
            }
            Text(appearance.detail)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 60, maxHeight: 60, alignment: .topLeading)
        .contentShape(Rectangle())
    }

    private var sectionDivider: some View {
        Divider()
            .overlay(Color.primary.opacity(0.04))
    }

    private var navigationActions: some View {
        HStack(spacing: 6) {
            ControlShortcut(title: "Ask", symbol: "sparkles", tint: .primary) { app.openMainWindow(section: .assistant) }
            ControlShortcut(title: "Follow Up", symbol: "checklist", tint: .primary) { app.openMainWindow(section: .followUp) }
        }
        .frame(height: 40)
    }

    @ViewBuilder private var captureActionSlot: some View {
        Group {
            if isAddingNote {
                noteEditor
            } else {
                HStack(spacing: 6) {
                    ControlShortcut(title: "Mark Moment", symbol: "bookmark.fill", tint: .primary) { Task { await app.markMoment() } }
                    ControlShortcut(title: "Add Note", symbol: "square.and.pencil", tint: .secondary) {
                        isAddingNote = true
                        interactionChanged?(true)
                    }
                }
            }
        }
        .frame(height: 38)
    }

    private var noteEditor: some View {
        HStack(spacing: 5) {
            TextField("Add a note…", text: $noteText)
                .textFieldStyle(.roundedBorder)
                .onSubmit(saveNote)
            Button {
                noteText = ""
                isAddingNote = false
                interactionChanged?(false)
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Cancel")
            Button(action: saveNote) {
                Image(systemName: "checkmark")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderedProminent)
            .tint(IrizTheme.violet)
            .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Save note")
        }
        .controlSize(.small)
    }

    private var controlRow: some View {
        HStack(spacing: 6) {
            pauseButton
            detailLevelMenu
            Button {
                app.openSettings()
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.caption.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .background(Color.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Settings")
            .accessibilityLabel("Open Settings")
        }
        .frame(height: 34)
    }

    private var detailLevelMenu: some View {
        Menu {
            Section("New follow-ups") {
                ForEach(FollowUpDetailLevel.allCases) { level in
                    Button {
                        settings.settings.followUpDetailLevel = level
                    } label: {
                        Label(
                            level.displayName,
                            systemImage: settings.settings.followUpDetailLevel == level
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "square.3.layers.3d")
                Text(settings.settings.followUpDetailLevel.displayName)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .frame(minWidth: 86, minHeight: 34)
            .background(Color.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
        .help("Follow-up detail: \(settings.settings.followUpDetailLevel.description) Applies only to new tiles.")
        .accessibilityLabel("Follow-up detail level, \(settings.settings.followUpDetailLevel.displayName)")
    }

    private var pauseButton: some View {
        Button {
            app.setPaused(!settings.settings.isPaused)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: settings.settings.isPaused ? "play.fill" : "pause.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(appearance.tint)
                Text(settings.settings.isPaused ? "Resume Iriz" : "Pause Iriz")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, minHeight: 34)
            .foregroundStyle(Color.primary)
            .background(Color.primary.opacity(0.075), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint(settings.settings.isPaused ? "Starts observation" : "Stops all observation")
    }

    private var footer: some View {
        HStack(spacing: 5) {
            if app.secureStorageState != .ready {
                Image(systemName: "lock.trianglebadge.exclamationmark")
                Text("Secure storage needs review")
                    .lineLimit(1)
            } else if app.pendingCount > 0 {
                Image(systemName: "lock.fill")
                Text("\(app.pendingCount) waiting securely")
                    .lineLimit(1)
            } else {
                Color.clear
            }
            Spacer(minLength: 0)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(app.secureStorageState == .ready ? Color.secondary : Color.orange)
        .frame(height: 14)
    }

    private func saveNote() {
        let value = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        noteText = ""
        isAddingNote = false
        interactionChanged?(false)
        Task { await app.addNote(value) }
    }
}

private struct StatusGlyph: View {
    let appearance: IndicatorPresentation

    var body: some View {
        IrizIndicatorView(
            presentation: appearance,
            logoSize: IrizIndicatorMetrics.logoSize
        )
        .frame(
            width: IrizIndicatorMetrics.collapsedPanelSize,
            height: IrizIndicatorMetrics.collapsedPanelSize
        )
        .accessibilityHidden(true)
    }
}

private struct ControlShortcut: View {
    let title: String
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                Text(title).font(.system(size: 9, weight: .medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(tint.opacity(0.075), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(title)
    }
}
