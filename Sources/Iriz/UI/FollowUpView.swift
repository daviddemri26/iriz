import SwiftUI

struct FollowUpView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Follow Up").font(.largeTitle.weight(.bold))
                    Text("Promises and useful loose ends Iriz noticed.").foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(22)
            Divider()
            if app.commitments.isEmpty {
                ContentUnavailableView("Nothing needs your attention", systemImage: "checkmark.circle", description: Text("Commitments appear only when Iriz finds useful evidence."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach([CommitmentState.needsAttention, .later, .waiting, .maybe], id: \.self) { state in
                            let values = app.commitments.filter { $0.state == state }
                            if !values.isEmpty {
                                Text(state.displayName).font(.title3.weight(.semibold))
                                ForEach(values) { commitment in CommitmentCard(commitment: commitment) }
                            }
                        }
                    }
                    .padding(22)
                }
            }
        }
    }
}

private struct CommitmentCard: View {
    @EnvironmentObject private var app: AppState
    let commitment: Commitment

    var body: some View {
        SoftCard {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: commitment.state == .maybe ? "questionmark.circle" : "circle.dashed.inset.filled")
                    .foregroundStyle(commitment.state == .maybe ? .orange : IrizTheme.violet)
                VStack(alignment: .leading, spacing: 6) {
                    Text(commitment.action).font(.headline)
                    if !commitment.rationale.isEmpty { Text(commitment.rationale).foregroundStyle(.secondary) }
                    if let date = commitment.explicitDueAt ?? commitment.suggestedReviewAt {
                        Label(date.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Menu("Snooze") {
                    Button("Tomorrow") { Task { await app.snoozeCommitment(commitment, days: 1) } }
                    Button("Next week") { Task { await app.snoozeCommitment(commitment, days: 7) } }
                    Button("Later, no date") { Task { await app.updateCommitment(commitment, state: .later) } }
                }
                Button("Done") { Task { await app.updateCommitment(commitment, state: .completed) } }
                    .buttonStyle(.borderedProminent).tint(IrizTheme.mint)
                Menu {
                    Button("Waiting") { Task { await app.updateCommitment(commitment, state: .waiting) } }
                    Button("Dismiss") { Task { await app.updateCommitment(commitment, state: .dismissed) } }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton)
                    .frame(width: 24)
            }
        }
    }
}
