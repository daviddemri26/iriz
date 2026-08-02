import SwiftUI

struct IrizStatusAppearance {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    let badge: String
    let breathes: Bool
    let breathingDuration: TimeInterval
}

extension CaptureHealth {
    var irizAppearance: IrizStatusAppearance {
        switch self {
        case .paused:
            IrizStatusAppearance(
                title: "Iriz is paused",
                detail: "Nothing is being captured.",
                symbol: "moon.zzz.fill",
                tint: .secondary,
                badge: "PAUSED",
                breathes: false,
                breathingDuration: 2.8
            )
        case .observing:
            IrizStatusAppearance(
                title: "Iriz is observing",
                detail: "The screen is active right now.",
                symbol: "eye.fill",
                tint: IrizTheme.mint,
                badge: "LIVE",
                breathes: true,
                breathingDuration: 2.8
            )
        case .listening:
            IrizStatusAppearance(
                title: "Iriz is listening",
                detail: "The microphone is active right now.",
                symbol: "waveform",
                tint: IrizTheme.violet,
                badge: "LIVE",
                breathes: true,
                breathingDuration: 2.2
            )
        case .observingAndListening:
            IrizStatusAppearance(
                title: "Iriz is observing and listening",
                detail: "Screen and microphone are active right now.",
                symbol: "eye.fill",
                tint: IrizTheme.violet,
                badge: "LIVE",
                breathes: true,
                breathingDuration: 2.2
            )
        case .waitingForSchedule:
            IrizStatusAppearance(
                title: "Iriz is waiting",
                detail: "Not observing or listening right now.",
                symbol: "clock.fill",
                tint: .secondary,
                badge: "WAITING",
                breathes: false,
                breathingDuration: 2.8
            )
        case .meeting:
            IrizStatusAppearance(
                title: "Meeting detected",
                detail: "Keeping context from this meeting.",
                symbol: "person.2.fill",
                tint: IrizTheme.coral,
                badge: "MEETING",
                breathes: true,
                breathingDuration: 1.9
            )
        case .processing:
            IrizStatusAppearance(
                title: "A moment stood out",
                detail: "Turning it into searchable memory.",
                symbol: "sparkles",
                tint: IrizTheme.violet,
                badge: "SAVING",
                breathes: true,
                breathingDuration: 1.35
            )
        case .permissionNeeded(let permission):
            IrizStatusAppearance(
                title: "Permission needed",
                detail: "Enable \(permission) to restore context.",
                symbol: "lock.trianglebadge.exclamationmark.fill",
                tint: .orange,
                badge: "CHECK",
                breathes: false,
                breathingDuration: 2.8
            )
        case .error:
            IrizStatusAppearance(
                title: "Iriz needs attention",
                detail: "Open Settings to review the issue.",
                symbol: "exclamationmark.triangle.fill",
                tint: .orange,
                badge: "CHECK",
                breathes: false,
                breathingDuration: 2.8
            )
        }
    }
}

enum ObservationControlMetrics {
    static let floatingWidth: CGFloat = 264
    static let cardHeight: CGFloat = 300
}

struct IrizStatusLegendItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let tint: Color
    let breathes: Bool
}

@MainActor
enum IrizStatusLegend {
    static var items: [IrizStatusLegendItem] {[
        IrizStatusLegendItem(
            id: "observe",
            title: "Mint · Observing",
            detail: "The screen is being observed now.",
            tint: IrizTheme.mint,
            breathes: true
        ),
        IrizStatusLegendItem(
            id: "listen",
            title: "Violet · Listening or saving",
            detail: "The microphone is active, both channels are active, or Iriz is saving a useful moment.",
            tint: IrizTheme.violet,
            breathes: true
        ),
        IrizStatusLegendItem(
            id: "meeting",
            title: "Coral · Meeting",
            detail: "A supported meeting is currently detected.",
            tint: IrizTheme.coral,
            breathes: true
        ),
        IrizStatusLegendItem(
            id: "idle",
            title: "Gray · Paused or waiting",
            detail: "No screen or microphone capture is happening now.",
            tint: .secondary,
            breathes: false
        ),
        IrizStatusLegendItem(
            id: "attention",
            title: "Orange · Attention needed",
            detail: "A permission or another issue needs review.",
            tint: .orange,
            breathes: false
        )
    ]}
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
                detail: settings.settings.captureTiming == .schedule ? "Screen · Scheduled" : "Screen",
                symbol: "eye.fill",
                tint: IrizTheme.mint,
                isSelected: app.isObserveEnabled
            ) {
                app.setObserveEnabled(!app.isObserveEnabled)
            }
            channelButton(
                title: "Listen",
                detail: settings.settings.captureTiming == .schedule ? "Mic · Scheduled" : "Microphone",
                symbol: "waveform",
                tint: IrizTheme.violet,
                isSelected: app.isListenEnabled
            ) {
                app.setListenEnabled(!app.isListenEnabled)
            }
        }
        .opacity(settings.settings.isPaused ? 0.78 : 1)
    }

    private func channelButton(
        title: String,
        detail: String,
        symbol: String,
        tint: Color,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: presentation == .compact ? 4 : 10) {
                Image(systemName: symbol)
                    .font(.system(size: presentation == .compact ? 11 : 14, weight: .semibold))
                    .foregroundStyle(isSelected ? tint : Color.secondary)
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
                        .foregroundStyle(isSelected ? tint : Color.secondary)
                }
            }
            .padding(.horizontal, presentation == .compact ? 7 : 12)
            .frame(maxWidth: .infinity, minHeight: presentation == .compact ? 34 : 50)
            .background(
                isSelected ? tint.opacity(0.12) : Color.primary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? tint.opacity(0.34) : Color.primary.opacity(0.06))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "On" : "Off")
        .help("Turn \(title.lowercased()) \(isSelected ? "off" : "on")")
    }
}

struct IrizBreathingLogo: View {
    @EnvironmentObject private var app: AppState
    @State private var isBreathing = false
    var size: CGFloat = 46

    private var appearance: IrizStatusAppearance { app.captureHealth.irizAppearance }

    var body: some View {
        ZStack {
            Circle()
                .stroke(appearance.tint.opacity(appearance.breathes ? (isBreathing ? 0.16 : 0.52) : 0.24), lineWidth: 1.6)
                .scaleEffect(appearance.breathes && isBreathing ? 1.08 : 0.97)
            IrizLogo(size: size, shape: .circle, castsShadow: false)
        }
        .frame(width: size + 4, height: size + 4)
        .animation(
            appearance.breathes
                ? .easeInOut(duration: appearance.breathingDuration).repeatForever(autoreverses: true)
                : .default,
            value: isBreathing
        )
        .task(id: appearance.title) {
            isBreathing = false
            guard appearance.breathes else { return }
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            isBreathing = true
        }
        .accessibilityLabel("Iriz · \(appearance.title)")
    }
}

struct ObservationControlCard: View {
    enum Placement {
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

    private var appearance: IrizStatusAppearance { app.captureHealth.irizAppearance }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            draggableHeader
            navigationActions
            captureActionSlot
            ObservationChannelsControl(presentation: .compact)
            controlRow
            footer
        }
        .padding(13)
        .frame(
            width: placement == .floating ? ObservationControlMetrics.floatingWidth : nil,
            height: ObservationControlMetrics.cardHeight,
            alignment: .top
        )
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThickMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(appearance.tint.opacity(0.055))
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

    private var statusHeader: some View {
        HStack(spacing: 8) {
            StatusGlyph(appearance: appearance)
            VStack(alignment: .leading, spacing: 2) {
                Text(appearance.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(appearance.detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.84)
            }
            .layoutPriority(1)
            Spacer()
            Text(appearance.badge)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .tracking(0.7)
                .foregroundStyle(appearance.tint)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(appearance.tint.opacity(0.12), in: Capsule())
        }
        .frame(height: 48)
    }

    private var navigationActions: some View {
        HStack(spacing: 6) {
            ControlShortcut(title: "Ask", symbol: "sparkles", tint: IrizTheme.violet) { app.openMainWindow(section: .assistant) }
            ControlShortcut(title: "Journal", symbol: "clock.arrow.circlepath", tint: IrizTheme.violet) { app.openMainWindow(section: .journal) }
            ControlShortcut(title: "Follow Up", symbol: "checklist", tint: IrizTheme.violet) { app.openMainWindow(section: .followUp) }
        }
        .frame(height: 40)
    }

    @ViewBuilder private var captureActionSlot: some View {
        Group {
            if isAddingNote {
                noteEditor
            } else {
                HStack(spacing: 6) {
                    ControlShortcut(title: "Mark Moment", symbol: "bookmark.fill", tint: IrizTheme.mint) { Task { await app.markMoment() } }
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
            Button {
                app.openMainWindow(section: .settings)
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

    private var pauseButton: some View {
        Button {
            app.setPaused(!settings.settings.isPaused)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: settings.settings.isPaused ? "play.fill" : "pause.fill")
                    .font(.caption.weight(.bold))
                Text(settings.settings.isPaused ? "Resume Iriz" : "Pause Iriz")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, minHeight: 34)
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
    let appearance: IrizStatusAppearance
    @State private var isBreathing = false

    var body: some View {
        ZStack {
            Circle().fill(appearance.tint.opacity(0.14))
            Circle()
                .stroke(appearance.tint.opacity(appearance.breathes ? (isBreathing ? 0.14 : 0.42) : 0.24), lineWidth: 1.2)
                .scaleEffect(appearance.breathes && isBreathing ? 1.13 : 0.98)
            Image(systemName: appearance.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(appearance.tint)
        }
        .frame(width: 34, height: 34)
        .animation(
            appearance.breathes
                ? .easeInOut(duration: appearance.breathingDuration).repeatForever(autoreverses: true)
                : .default,
            value: isBreathing
        )
        .task(id: appearance.title) {
            isBreathing = false
            guard appearance.breathes else { return }
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            isBreathing = true
        }
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
