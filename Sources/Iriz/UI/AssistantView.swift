import SwiftUI

struct AssistantView: View {
    @EnvironmentObject private var app: AppState
    @State private var question = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ask Iriz").font(.largeTitle.weight(.bold))
                    Text("Search your memory without sending your full history.").foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(22)
            Divider()
            ScrollView {
                LazyVStack(spacing: 16) {
                    if app.assistantHistory.isEmpty {
                        SuggestedQuestions { question = $0; submit() }
                    }
                    ForEach(app.assistantHistory) { answer in AnswerCard(answer: answer) }
                }
                .padding(22)
            }
            Divider()
            HStack(spacing: 10) {
                TextField("Ask about a company, appointment, purchase, document or promise…", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                Button(action: submit) {
                    if app.isAsking { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.up") }
                }
                .buttonStyle(.borderedProminent).tint(IrizTheme.violet)
                .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || app.isAsking)
            }
            .padding(16)
        }
    }

    private func submit() {
        let value = question
        question = ""
        Task { await app.ask(value) }
    }
}

private struct SuggestedQuestions: View {
    let select: (String) -> Void
    private let questions = [
        "Which company did I apply to for the automotive camera role?",
        "What purchases did I confirm this week?",
        "What did I promise to follow up on?"
    ]

    var body: some View {
        VStack(spacing: 14) {
            IrizLogo(size: 54)
            Text("What would you like to remember?").font(.title2.weight(.semibold))
            ForEach(questions, id: \.self) { value in
                Button(value) { select(value) }.buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
    }
}

private struct AnswerCard: View {
    @EnvironmentObject private var app: AppState
    let answer: AssistantAnswer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(answer.question).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(answer.text).font(.body).textSelection(.enabled)
            ForEach(answer.citations) { citation in
                Button {
                    app.openEvent(citation.eventID)
                } label: {
                    HStack {
                        Image(systemName: "quote.bubble")
                        Text(citation.title).lineLimit(1)
                        Spacer()
                        Text(citation.timestamp, style: .date)
                        Image(systemName: "chevron.right")
                    }
                    .font(.caption)
                    .padding(9)
                    .background(IrizTheme.violet.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(IrizTheme.card, in: RoundedRectangle(cornerRadius: 16))
    }
}
