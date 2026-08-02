import SwiftUI

struct FloatingCapsuleView: View {
    @ObservedObject var model: FloatingCapsuleModel
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Group {
            if model.isExpanded { expandedView } else { collapsedView }
        }
        .animation(.snappy(duration: 0.28), value: model.isExpanded)
        .onHover(perform: model.hover)
    }

    private var collapsedView: some View {
        ZStack(alignment: .topTrailing) {
            IrizLogo(size: 44, shape: .circle).padding(2)
            if app.latestInsight != nil {
                Circle().fill(IrizTheme.coral).frame(width: 10, height: 10)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
            }
        }
        .frame(width: 48, height: 48)
        .contentShape(Circle())
        .help("Iriz · \(app.observationStatusText)")
    }

    private var expandedView: some View {
        VStack(spacing: 11) {
            HStack(spacing: 9) {
                IrizLogo(size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Iriz").font(.headline)
                    Text(app.observationStatusText).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button {
                    app.setPaused(!settings.settings.isPaused)
                } label: {
                    Image(systemName: settings.settings.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.borderedProminent).tint(settings.settings.isPaused ? IrizTheme.violet : .secondary)
                .controlSize(.small)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { _ in model.dragChanged() }
                    .onEnded { _ in model.dragEnded() }
            )

            if model.isAddingNote {
                TextField("Add a note…", text: $model.noteText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveNote)
                HStack {
                    Button("Cancel") { model.isAddingNote = false }
                    Spacer()
                    Button("Save", action: saveNote).buttonStyle(.borderedProminent).tint(IrizTheme.violet)
                }
            } else {
                if let insight = app.latestInsight {
                    Button { app.openEvent(insight.id) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: insight.kind.symbolName).foregroundStyle(IrizTheme.violet)
                            Text(insight.title).font(.caption.weight(.medium)).lineLimit(2)
                            Spacer()
                        }
                        .padding(9)
                        .background(IrizTheme.violet.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    QuickAction(title: "Mark Moment", icon: "bookmark.fill") { Task { await app.markMoment() } }
                    QuickAction(title: "Add Note", icon: "square.and.pencil") { model.isAddingNote = true }
                    QuickAction(title: "Ask Iriz", icon: "sparkles") { app.openMainWindow(section: .assistant) }
                    QuickAction(title: "Journal", icon: "clock.arrow.circlepath") { app.openMainWindow(section: .journal) }
                }
                Picker("Mode", selection: Binding(
                    get: { app.observationMode },
                    set: { app.setObservationMode($0) }
                )) {
                    ForEach(ObservationMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                HStack {
                    if app.pendingCount > 0 { Text("\(app.pendingCount) waiting").font(.caption2).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Settings") { app.openMainWindow(section: .settings) }.buttonStyle(.plain).font(.caption)
                }
            }
        }
        .padding(13)
        .frame(width: 264, height: 286, alignment: .top)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.22)))
    }

    private func saveNote() {
        let value = model.noteText
        model.noteText = ""
        model.isAddingNote = false
        Task { await app.addNote(value) }
    }
}

private struct QuickAction: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                Text(title).font(.caption2).lineLimit(1)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
    }
}
