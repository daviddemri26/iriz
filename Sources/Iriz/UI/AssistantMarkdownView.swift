import Foundation
import SwiftUI

struct AssistantMarkdownDocument: Equatable, Sendable {
    struct OrderedItem: Equatable, Sendable {
        let number: Int
        let text: String
    }

    enum Block: Equatable, Sendable {
        case paragraph(String)
        case heading(level: Int, text: String)
        case unorderedList([String])
        case orderedList([OrderedItem])
        case quote(String)
        case code(String)
        case horizontalRule
    }

    let blocks: [Block]

    init(markdown: String) {
        blocks = Self.parse(markdown)
    }

    private static func parse(_ markdown: String) -> [Block] {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [Block] = []
        var paragraphLines: [String] = []
        var codeLines: [String] = []
        var activeFence: String?

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
            paragraphLines.removeAll(keepingCapacity: true)
        }

        func appendUnorderedItem(_ text: String) {
            if case .unorderedList(var items)? = blocks.last {
                blocks.removeLast()
                items.append(text)
                blocks.append(.unorderedList(items))
            } else {
                blocks.append(.unorderedList([text]))
            }
        }

        func appendOrderedItem(_ item: OrderedItem) {
            if case .orderedList(var items)? = blocks.last {
                blocks.removeLast()
                items.append(item)
                blocks.append(.orderedList(items))
            } else {
                blocks.append(.orderedList([item]))
            }
        }

        func appendQuoteLine(_ text: String) {
            if case .quote(let existing)? = blocks.last {
                blocks.removeLast()
                blocks.append(.quote("\(existing)\n\(text)"))
            } else {
                blocks.append(.quote(text))
            }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let fence = activeFence {
                if trimmed.hasPrefix(fence) {
                    blocks.append(.code(codeLines.joined(separator: "\n")))
                    codeLines.removeAll(keepingCapacity: true)
                    activeFence = nil
                } else {
                    codeLines.append(line)
                }
                continue
            }

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                activeFence = String(trimmed.prefix(3))
                continue
            }

            guard !trimmed.isEmpty else {
                flushParagraph()
                continue
            }

            if let heading = heading(from: trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                continue
            }

            if isHorizontalRule(trimmed) {
                flushParagraph()
                blocks.append(.horizontalRule)
                continue
            }

            if let item = unorderedItem(from: trimmed) {
                flushParagraph()
                appendUnorderedItem(item)
                continue
            }

            if let item = orderedItem(from: trimmed) {
                flushParagraph()
                appendOrderedItem(item)
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                let quote = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                appendQuoteLine(quote)
                continue
            }

            paragraphLines.append(line.trimmingCharacters(in: .whitespaces))
        }

        flushParagraph()
        if activeFence != nil || !codeLines.isEmpty {
            blocks.append(.code(codeLines.joined(separator: "\n")))
        }
        if blocks.isEmpty, !normalized.isEmpty {
            blocks.append(.paragraph(normalized))
        }
        return blocks
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        let level = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level), line.dropFirst(level).first == " " else { return nil }
        let text = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
        return (level, text)
    }

    private static func unorderedItem(from line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private static func orderedItem(from line: String) -> OrderedItem? {
        guard let period = line.firstIndex(of: ".") else { return nil }
        let numberText = line[..<period]
        guard let number = Int(numberText) else { return nil }
        let remainderStart = line.index(after: period)
        guard remainderStart < line.endIndex, line[remainderStart].isWhitespace else { return nil }
        let text = line[remainderStart...].trimmingCharacters(in: .whitespaces)
        return OrderedItem(number: number, text: text)
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let marker = compact.first, "-*_".contains(marker) else { return false }
        return compact.allSatisfy { $0 == marker }
    }
}

struct AssistantMarkdownView: View {
    private let document: AssistantMarkdownDocument

    init(markdown: String) {
        document = AssistantMarkdownDocument(markdown: markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder private func blockView(_ block: AssistantMarkdownDocument.Block) -> some View {
        switch block {
        case .paragraph(let text):
            inlineText(text)
                .font(.system(size: 16))
                .lineSpacing(6)

        case .heading(let level, let text):
            inlineText(text)
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 2 : 0)

        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text("•")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(IrizTheme.violet)
                            .frame(width: 13, alignment: .trailing)
                        inlineText(item)
                            .font(.system(size: 16))
                            .lineSpacing(5)
                    }
                }
            }

        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text("\(item.number).")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(IrizTheme.violet)
                            .frame(width: 24, alignment: .trailing)
                        inlineText(item.text)
                            .font(.system(size: 16))
                            .lineSpacing(5)
                    }
                }
            }

        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(IrizTheme.violet.opacity(0.72))
                    .frame(width: 3)
                inlineText(text)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .lineSpacing(5)
                    .padding(.vertical, 2)
            }

        case .code(let text):
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(size: 13, design: .monospaced))
                    .lineSpacing(4)
                    .padding(12)
            }
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.08))
            }

        case .horizontalRule:
            Divider()
        }
    }

    private func inlineText(_ source: String) -> Text {
        let attributed = (try? AttributedString(
            markdown: source,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(source)
        return Text(attributed)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.weight(.bold)
        case 2: .title3.weight(.bold)
        default: .headline.weight(.semibold)
        }
    }
}
