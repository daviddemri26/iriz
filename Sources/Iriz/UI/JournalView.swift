import SwiftUI

struct JournalView: View {
    @EnvironmentObject private var app: AppState
    @State private var search = ""
    @State private var importantOnly = true

    private var filteredEvents: [ActivityEvent] {
        app.events.filter { event in
            (!importantOnly || event.importance >= .important) &&
            (search.isEmpty || event.searchableText.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if filteredEvents.isEmpty {
                ContentUnavailableView(
                    search.isEmpty ? "Your useful moments will appear here" : "No matching moments",
                    systemImage: search.isEmpty ? "sparkles" : "magnifyingglass",
                    description: Text(search.isEmpty ? "Iriz keeps routine app activity quiet and brings forward actions, decisions, purchases, applications, appointments and commitments." : "Try another word or switch to All Activity.")
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(filteredEvents) { event in
                                EventCard(event: event)
                                    .id(event.id)
                            }
                        }
                        .padding(22)
                    }
                    .onChange(of: app.selectedEventID) { _, id in
                        if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
            }
        }
        .navigationTitle("Journal")
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Journal").font(.largeTitle.weight(.bold))
                Text("What mattered, without the noise.").foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Activity", selection: $importantOnly) {
                Text("Important").tag(true)
                Text("All Activity").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(width: 210)
            TextField("Search people, companies or URLs", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
        }
        .padding(22)
    }
}

struct EventCard: View {
    let event: ActivityEvent
    @State private var expanded = false

    var body: some View {
        SoftCard {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: event.kind.symbolName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(event.importance >= .important ? IrizTheme.violet : .secondary)
                        .frame(width: 34, height: 34)
                        .background(IrizTheme.violet.opacity(0.10), in: Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.title).font(.headline)
                        Text(event.summary).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(event.startedAt, style: .time).font(.caption.weight(.medium))
                        Text(event.status.displayName)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(statusColor.opacity(0.12), in: Capsule())
                            .foregroundStyle(statusColor)
                    }
                }
                if let url = event.urls.first {
                    Link(destination: url) {
                        Label(url.host() ?? url.absoluteString, systemImage: "arrow.up.right.square")
                            .font(.caption)
                    }
                }
                if expanded {
                    Divider()
                    if !event.details.isEmpty { Text(event.details).font(.callout).textSelection(.enabled) }
                    if !event.entities.isEmpty {
                        Text(event.entities.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Label("\(Int(event.confidence * 100))% confidence", systemImage: "waveform.path.ecg")
                        Spacer()
                        Text("\(event.evidence.count) evidence reference\(event.evidence.count == 1 ? "" : "s")")
                    }
                    .font(.caption2).foregroundStyle(.tertiary)
                }
                Button(expanded ? "Less" : "Details") { withAnimation(.snappy) { expanded.toggle() } }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(IrizTheme.violet)
            }
        }
        .overlay {
            if AppState.shared.selectedEventID == event.id {
                RoundedRectangle(cornerRadius: 16).stroke(IrizTheme.violet, lineWidth: 2)
            }
        }
    }

    private var statusColor: Color {
        switch event.status {
        case .completed: IrizTheme.mint
        case .inProgress: .orange
        case .observed: .secondary
        case .uncertain: .purple
        }
    }
}
