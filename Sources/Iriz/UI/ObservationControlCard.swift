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
                detail: "Ready to remember useful moments.",
                symbol: "eye.fill",
                tint: IrizTheme.mint,
                badge: "LIVE",
                breathes: true,
                breathingDuration: 2.8
            )
        case .listening:
            IrizStatusAppearance(
                title: "Iriz is listening",
                detail: "Listening for useful spoken context.",
                symbol: "waveform",
                tint: IrizTheme.violet,
                badge: "LIVE",
                breathes: true,
                breathingDuration: 2.2
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
        .onAppear { isBreathing = true }
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
        VStack(alignment: .leading, spacing: 10) {
            draggableHeader
            statusCopy

            if isAddingNote {
                noteEditor
            } else {
                quickActions
            }

            modePicker
            pauseButton
            footer
        }
        .padding(13)
        .frame(
            width: placement == .floating ? 264 : nil,
            height: placement == .floating ? 286 : nil,
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
        HStack(spacing: 10) {
            StatusGlyph(appearance: appearance)
            Spacer()
            Text(appearance.badge)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .tracking(0.7)
                .foregroundStyle(appearance.tint)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(appearance.tint.opacity(0.12), in: Capsule())
        }
    }

    private var statusCopy: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(appearance.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.86)
            Text(appearance.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var quickActions: some View {
        HStack(spacing: 6) {
            ControlShortcut(title: "Mark", symbol: "bookmark.fill") { Task { await app.markMoment() } }
            ControlShortcut(title: "Note", symbol: "square.and.pencil") {
                isAddingNote = true
                interactionChanged?(true)
            }
            ControlShortcut(title: "Ask", symbol: "sparkles") { app.openMainWindow(section: .assistant) }
            ControlShortcut(title: "Journal", symbol: "clock.arrow.circlepath") { app.openMainWindow(section: .journal) }
        }
    }

    private var noteEditor: some View {
        VStack(spacing: 6) {
            TextField("Add a note…", text: $noteText)
                .textFieldStyle(.roundedBorder)
                .onSubmit(saveNote)
            HStack {
                Button("Cancel") {
                    isAddingNote = false
                    interactionChanged?(false)
                }
                Spacer()
                Button("Save", action: saveNote)
                    .buttonStyle(.borderedProminent)
                    .tint(IrizTheme.violet)
            }
            .controlSize(.small)
        }
    }

    private var modePicker: some View {
        HStack(spacing: 8) {
            Text("Mode").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Picker("Mode", selection: Binding(
                get: { app.observationMode },
                set: { app.setObservationMode($0) }
            )) {
                ForEach(ObservationMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: 150)
        }
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
                Text("⇧⌘P")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .opacity(0.72)
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

    @ViewBuilder private var footer: some View {
        if app.pendingCount > 0 || placement == .floating || app.secureStorageState != .ready {
            HStack(spacing: 6) {
                if app.pendingCount > 0 {
                    Image(systemName: "lock.fill")
                    Text("\(app.pendingCount) waiting")
                }
                Spacer()
                if placement == .floating || app.secureStorageState != .ready {
                    Button(app.secureStorageState == .ready ? "Settings" : "Review") {
                        app.openMainWindow(section: .settings)
                    }
                        .buttonStyle(.plain)
                }
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
        }
    }

    private func saveNote() {
        let value = noteText
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
        .onAppear { isBreathing = true }
    }
}

private struct ControlShortcut: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.caption.weight(.semibold))
                Text(title).font(.system(size: 9, weight: .medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(Color.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(title)
    }
}
