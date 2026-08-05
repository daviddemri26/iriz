import SwiftUI

enum ObservationControlMetrics {
    static let cardWidth: CGFloat = 276
    static let cardHeight: CGFloat = 252
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

    var placement: Placement = .sidebar
    var dragChanged: (() -> Void)?
    var dragEnded: (() -> Void)?
    var isPinned = false
    var pinChanged: (() -> Void)?

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
        VStack(alignment: .leading, spacing: 8) {
            channelControls
            navigationActions
            detailLevelRow
            utilityActions
            draggableStatusFooter
        }
        .padding(12)
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

    private var channelControls: some View {
        ObservationChannelsControl(presentation: .compact)
            .padding(.leading, 44)
            .frame(height: 34)
    }

    @ViewBuilder private var draggableStatusFooter: some View {
        if placement == .floating {
            statusFooter
                .contentShape(Rectangle())
                .simultaneousGesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { _ in dragChanged?() }
                        .onEnded { _ in dragEnded?() }
                )
        } else {
            statusFooter
        }
    }

    @ViewBuilder private var statusFooter: some View {
        if let settingsDestination {
            Button {
                app.openSettings(category: settingsDestination)
            } label: {
                statusFooterContent
            }
            .buttonStyle(.plain)
            .help("Open Privacy settings")
            .accessibilityHint("Opens the Privacy category in iriz Settings")
        } else {
            statusFooterContent
        }
    }

    private var statusFooterContent: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusTint)
                .frame(width: 7, height: 7)
                .shadow(color: statusTint.opacity(0.34), radius: 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(appearance.title)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text(statusDetail)
                    .font(.system(size: 8.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            Spacer(minLength: 2)
            if settingsDestination != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(statusTint.opacity(0.16))
        }
        .contentShape(Rectangle())
        .help(appearance.detail)
    }

    private var statusTint: Color {
        app.secureStorageState == .ready ? appearance.tint : Color.orange
    }

    private var statusDetail: String {
        if app.secureStorageState != .ready {
            return "Secure storage needs review"
        }
        if app.pendingCount > 0 {
            return "\(app.pendingCount) waiting securely"
        }
        return appearance.detail
    }

    private var navigationActions: some View {
        HStack(spacing: 6) {
            CompactFeatureShortcut(
                title: "Actions",
                symbol: "checkmark.circle.fill",
                colors: [IrizTheme.observing, IrizTheme.mint]
            ) {
                app.openMainWindow(section: .followUp)
            }
            CompactFeatureShortcut(
                title: "Ask",
                symbol: "sparkles",
                colors: [IrizTheme.violet, IrizTheme.coral]
            ) {
                app.openMainWindow(section: .assistant)
            }
        }
        .frame(height: 48)
    }

    private var detailLevelRow: some View {
        HStack(spacing: 8) {
            Label("Action detail", systemImage: "square.3.layers.3d")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 2)
            detailLevelMenu
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.06))
        }
    }

    private var utilityActions: some View {
        HStack(spacing: 7) {
            pauseButton
            Spacer(minLength: 0)
            if placement == .floating {
                pinButton
            }
            Button {
                app.openSettings()
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.caption.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .background(Color.primary.opacity(0.065), in: Circle())
                    .overlay(Circle().stroke(Color.primary.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .help("Settings")
            .accessibilityLabel("Open Settings")
        }
        .frame(height: 34)
    }

    private var pinButton: some View {
        Button {
            pinChanged?()
        } label: {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isPinned ? Color.white : Color.primary)
                .frame(width: 34, height: 34)
                .background(isPinned ? IrizTheme.violet : Color.primary.opacity(0.065), in: Circle())
                .overlay(Circle().stroke(isPinned ? Color.white.opacity(0.24) : Color.primary.opacity(0.07)))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(isPinned ? "Unpin controls" : "Keep controls open")
        .accessibilityLabel(isPinned ? "Unpin controls" : "Pin controls open")
        .accessibilityValue(isPinned ? "Pinned" : "Not pinned")
    }

    private var detailLevelMenu: some View {
        Menu {
            Section("New Actions") {
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
                Text(settings.settings.followUpDetailLevel.displayName)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .frame(minWidth: 92, minHeight: 28)
            .background(Color.primary.opacity(0.075), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
        .help("Action detail: \(settings.settings.followUpDetailLevel.description) Applies only to new Actions.")
        .accessibilityLabel("Action detail level, \(settings.settings.followUpDetailLevel.displayName)")
    }

    private var pauseButton: some View {
        Button {
            app.setPaused(!settings.settings.isPaused)
        } label: {
            Image(systemName: settings.settings.isPaused ? "play.fill" : "pause.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(settings.settings.isPaused ? IrizTheme.listening : appearance.tint)
                .frame(width: 34, height: 34)
                .background(Color.primary.opacity(0.075), in: Circle())
                .overlay(Circle().stroke(appearance.tint.opacity(0.16)))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(settings.settings.isPaused ? "Resume iriz" : "Pause iriz")
        .accessibilityLabel(settings.settings.isPaused ? "Resume iriz" : "Pause iriz")
        .accessibilityHint(settings.settings.isPaused ? "Starts observation" : "Stops all observation")
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

private struct CompactFeatureShortcut: View {
    let title: String
    let symbol: String
    let colors: [Color]
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.white.opacity(0.96))
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background {
                ZStack(alignment: .trailing) {
                    LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                    Circle()
                        .fill(Color.white.opacity(0.11))
                        .frame(width: 48, height: 48)
                        .offset(x: 14, y: -13)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Color.white.opacity(isHovered ? 0.34 : 0.16))
            }
            .shadow(color: colors.first?.opacity(isHovered ? 0.30 : 0.14) ?? .clear, radius: isHovered ? 8 : 4, y: 3)
            .scaleEffect(isHovered ? 1.015 : 1)
        }
        .buttonStyle(.plain)
        .help(title)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.16)) {
                isHovered = inside
            }
        }
    }
}
