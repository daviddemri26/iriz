import SwiftUI

/// A focused provenance view for assistant citations and Action evidence.
/// Structured events remain iriz's private memory layer without being exposed
/// as a standalone customer-facing timeline.
struct SourceDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let event: ActivityEvent

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    overview
                    if !event.details.isEmpty { details }
                    if !event.urls.isEmpty { links }
                    evidence
                }
                .padding(24)
            }
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 520, idealHeight: 650)
        .background(IrizTheme.canvas)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: event.kind.symbolName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(IrizTheme.violet)
                .frame(width: 40, height: 40)
                .background(IrizTheme.violet.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text("Memory source")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(event.title)
                    .font(.title2.weight(.bold))
                    .lineLimit(2)
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(22)
    }

    private var overview: some View {
        sourceSection("What iriz retained", symbol: "text.quote") {
            VStack(alignment: .leading, spacing: 12) {
                Text(event.summary)
                    .font(.body)
                    .textSelection(.enabled)
                HStack(spacing: 14) {
                    Label(fullDate(event.startedAt), systemImage: "calendar")
                    Label(event.status.displayName, systemImage: "circle.fill")
                    if !event.sourceApplications.isEmpty {
                        Label(event.sourceApplications.joined(separator: ", "), systemImage: "app")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var details: some View {
        sourceSection("Details", symbol: "text.alignleft") {
            Text(event.details)
                .font(.callout)
                .textSelection(.enabled)
        }
    }

    private var links: some View {
        sourceSection("Links", symbol: "link") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(event.urls, id: \.absoluteString) { url in
                    Link(destination: url) {
                        Label(url.absoluteString, systemImage: "arrow.up.right.square")
                            .lineLimit(1)
                    }
                }
            }
            .font(.callout)
        }
    }

    private var evidence: some View {
        sourceSection("Evidence", symbol: "checkmark.seal") {
            if event.evidence.isEmpty {
                Text("No raw evidence reference is attached to this memory.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(event.evidence) { reference in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Label(reference.source.sourceDisplayName, systemImage: reference.source.sourceSymbol)
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Text(fullDate(reference.capturedAt))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let excerpt = reference.excerpt, !excerpt.isEmpty {
                                Text(excerpt)
                                    .font(.callout)
                                    .textSelection(.enabled)
                            }
                            if reference.expiresAt.map({ $0 <= Date() }) == true {
                                Label("Raw media expired; the structured source remains.", systemImage: "clock.badge.xmark")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
    }

    private func sourceSection<Content: View>(
        _ title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        SoftCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(title, systemImage: symbol)
                    .font(.headline)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func fullDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

private extension ObservationSource {
    var sourceDisplayName: String {
        switch self {
        case .screen: "Screen capture"
        case .ambientAudio: "Ambient audio"
        case .meetingMicrophone: "Meeting microphone"
        case .meetingSystemAudio: "Meeting system audio"
        case .manualNote: "Manual note"
        }
    }

    var sourceSymbol: String {
        switch self {
        case .screen: "rectangle.inset.filled"
        case .ambientAudio: "waveform"
        case .meetingMicrophone: "mic.fill"
        case .meetingSystemAudio: "speaker.wave.2.fill"
        case .manualNote: "note.text"
        }
    }
}
