import Foundation
import SwiftUI

struct AssistantView: View {
    @EnvironmentObject private var app: AppState
    @State private var question = ""

    var body: some View {
        HStack(spacing: 0) {
            conversationSidebar
            Divider()
            conversationPane
        }
        .background(IrizTheme.canvas)
        .onChange(of: app.selectedAssistantConversationID) { _, _ in
            question = ""
        }
    }

    private var conversationSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Conversations")
                    .font(.headline)
                Spacer()
                Button {
                    app.startNewAssistantConversation()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("New conversation")
                .accessibilityLabel("New conversation")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)

            Divider()

            if app.assistantConversations.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Your conversations will appear here.")
                        .font(.callout.weight(.medium))
                    Text("Each thread keeps its own Action context.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(app.assistantConversations) { conversation in
                            conversationButton(conversation)
                        }
                    }
                    .padding(8)
                }
                .scrollIndicators(.hidden)
            }

            Divider()
            Label("Encrypted on this Mac", systemImage: "lock.fill")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(12)
        }
        .frame(width: 232)
        .background(Color.primary.opacity(0.018))
    }

    private func conversationButton(_ conversation: AssistantConversation) -> some View {
        let isSelected = app.selectedAssistantConversationID == conversation.id
        return HStack(spacing: 2) {
            Button {
                app.selectAssistantConversation(conversation.id)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(conversation.title)
                        .font(.callout.weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(Color.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 5) {
                        Text(conversation.updatedAt, format: .relative(presentation: .named))
                        Text("·")
                        Text("\(conversation.answers.count) repl\(conversation.answers.count == 1 ? "y" : "ies")")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .padding(.leading, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                Task { await app.toggleAssistantConversationPinned(conversation.id) }
            } label: {
                Image(systemName: conversation.pinnedAt == nil ? "pin" : "pin.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(conversation.pinnedAt == nil ? Color.secondary : IrizTheme.violet)
                    .frame(width: 28, height: 34)
            }
            .buttonStyle(.plain)
            .help(conversation.pinnedAt == nil ? "Pin conversation" : "Unpin conversation")
            .accessibilityLabel(conversation.pinnedAt == nil ? "Pin conversation" : "Unpin conversation")
        }
        .padding(.trailing, 4)
        .background(
            isSelected ? Color.primary.opacity(0.10) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .contextMenu {
            Button(conversation.pinnedAt == nil ? "Pin Conversation" : "Unpin Conversation") {
                Task { await app.toggleAssistantConversationPinned(conversation.id) }
            }
            Button("Delete Conversation", role: .destructive) {
                Task { await app.deleteAssistantConversation(conversation.id) }
            }
            .disabled(app.pendingAssistantTurn?.conversationID == conversation.id)
        }
    }

    private var conversationPane: some View {
        VStack(spacing: 0) {
            conversationHeader
            Divider()
            messages
            Divider()
            composer
        }
    }

    private var conversationHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(app.selectedAssistantConversation?.title ?? "Ask iriz")
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                Text("Search your local memory. Only the most relevant evidence and this thread’s recent context are sent for an answer.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if let conversation = app.selectedAssistantConversation {
                Button {
                    Task { await app.toggleAssistantConversationPinned(conversation.id) }
                } label: {
                    Label(
                        conversation.pinnedAt == nil ? "Pin" : "Unpin",
                        systemImage: conversation.pinnedAt == nil ? "pin" : "pin.slash"
                    )
                }
                .buttonStyle(.bordered)
                .help(conversation.pinnedAt == nil
                    ? "Keep this conversation in the main sidebar"
                    : "Remove this conversation from the main sidebar")
            }
            Button {
                app.startNewAssistantConversation()
            } label: {
                Label("New", systemImage: "plus")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if app.assistantHistory.isEmpty && activePendingTurn == nil {
                        SuggestedQuestions(select: send)
                    } else {
                        ForEach(app.assistantHistory) { answer in
                            UserMessageBubble(text: answer.question)
                                .id("question-\(answer.id.uuidString)")
                            AssistantMessage(answer: answer)
                                .id(answer.id)
                        }
                        if let pending = activePendingTurn {
                            UserMessageBubble(text: pending.question)
                                .id("pending-question")
                            WaitingForAnswer()
                                .id("waiting-for-answer")
                        }
                    }
                    Color.clear.frame(height: 1).id("conversation-bottom")
                }
                .frame(maxWidth: 900)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: app.assistantHistory.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: activePendingTurn?.id) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: app.selectedAssistantConversationID) { _, _ in
                DispatchQueue.main.async { scrollToBottom(proxy, animated: false) }
            }
        }
    }

    private var activePendingTurn: PendingAssistantTurn? {
        guard let pending = app.pendingAssistantTurn,
              pending.conversationID == app.selectedAssistantConversationID else { return nil }
        return pending
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(
                "Ask about a company, meeting, trip, purchase, document or promise…",
                text: $question,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.body)
            .lineLimit(1...4)
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.08))
            }
            .onSubmit(submit)

            Button(action: submit) {
                Image(systemName: app.isAsking ? "hourglass" : "arrow.up")
                    .font(.callout.weight(.bold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderedProminent)
            .tint(IrizTheme.violet)
            .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || app.isAsking)
            .help(app.isAsking ? "iriz is answering" : "Send")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func submit() {
        send(question)
    }

    private func send(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !app.isAsking else { return }
        question = ""
        Task { await app.ask(trimmed) }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo("conversation-bottom", anchor: .bottom)
                }
            } else {
                proxy.scrollTo("conversation-bottom", anchor: .bottom)
            }
        }
    }
}

private struct SuggestedPrompt: Identifiable {
    let id: String
    let category: String
    let symbol: String
    let question: String
}

private struct SuggestedQuestions: View {
    let select: (String) -> Void
    private let prompts = [
        SuggestedPrompt(
            id: "business", category: "Business", symbol: "briefcase.fill",
            question: "Summarize the important decisions and commitments from my client meetings this week."
        ),
        SuggestedPrompt(
            id: "personal", category: "Personal", symbol: "person.fill",
            question: "What important personal tasks did I say I would handle but have not revisited yet?"
        ),
        SuggestedPrompt(
            id: "travel", category: "Travel", symbol: "airplane",
            question: "Find the hotels, flights or destinations I researched for my next trip, with the exact URLs."
        ),
        SuggestedPrompt(
            id: "purchase", category: "Purchase", symbol: "bag.fill",
            question: "Which products did I compare recently, and which purchase was actually confirmed?"
        ),
        SuggestedPrompt(
            id: "career", category: "Career", symbol: "building.2.fill",
            question: "Which company did I apply to for the automotive camera role, and what was the job URL?"
        )
    ]

    private let columns = [GridItem(.adaptive(minimum: 260, maximum: 380), spacing: 10)]

    var body: some View {
        VStack(spacing: 18) {
            IrizLogo(size: 58)
            VStack(spacing: 5) {
                Text("What would you like to remember?")
                    .font(.title2.weight(.semibold))
                Text("Ask naturally. iriz searches your memory on this Mac before composing an answer.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(prompts) { prompt in
                    Button { select(prompt.question) } label: {
                        HStack(alignment: .top, spacing: 11) {
                            Image(systemName: prompt.symbol)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(IrizTheme.violet)
                                .frame(width: 24, height: 24)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(prompt.category)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.secondary)
                                Text(prompt.question)
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(Color.primary)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(13)
                        .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(Color.primary.opacity(0.07))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 760)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 38)
    }
}

private struct UserMessageBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 80)
            Text(text)
                .font(.system(size: 15, weight: .medium))
                .lineSpacing(3)
                .textSelection(.enabled)
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
                .background(Color.primary.opacity(0.085), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .frame(maxWidth: .infinity)
    }
}

private struct WaitingForAnswer: View {
    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            IrizLogo(size: 30, shape: .circle, castsShadow: false)
            HStack(spacing: 9) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("iriz is looking through your memory…")
                        .font(.callout.weight(.semibold))
                    Text("Searching locally, then preparing a sourced answer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(IrizTheme.violet.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Spacer(minLength: 80)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct AssistantMessage: View {
    @EnvironmentObject private var app: AppState
    let answer: AssistantAnswer

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            IrizLogo(size: 30, shape: .circle, castsShadow: false)
            VStack(alignment: .leading, spacing: 14) {
                AssistantMarkdownView(markdown: answer.text)
                if !answer.citations.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Sources")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                        ForEach(answer.citations) { citation in
                            citationButton(citation)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 50)
        }
        .frame(maxWidth: .infinity)
    }

    private func citationButton(_ citation: AssistantCitation) -> some View {
        Button {
            app.openEvent(citation.eventID)
        } label: {
            HStack(spacing: 9) {
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
