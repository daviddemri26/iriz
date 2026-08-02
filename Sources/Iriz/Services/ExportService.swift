@preconcurrency import AppKit
import Foundation

enum ExportFormat: String, Sendable {
    case json
    case markdown
}

struct IrizExport: Codable, Sendable {
    var exportedAt: Date
    var events: [ActivityEvent]
    var commitments: [Commitment]
}

enum ExportService {
    static func render(events: [ActivityEvent], commitments: [Commitment], format: ExportFormat, now: Date = Date()) throws -> Data {
        let sanitizedEvents = events.map { event in
            var copy = event
            copy.evidence = event.evidence.map { evidence in
                var evidence = evidence
                if let expiresAt = evidence.expiresAt, expiresAt <= now { evidence.mediaIdentifier = nil }
                return evidence
            }
            return copy
        }
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(IrizExport(exportedAt: now, events: sanitizedEvents, commitments: commitments))
        case .markdown:
            var lines = ["# Iriz Journal", "", "Exported \(now.formatted(date: .long, time: .shortened))", ""]
            for event in sanitizedEvents {
                lines.append("## \(event.title)")
                lines.append("")
                lines.append("- Time: \(event.startedAt.formatted(date: .abbreviated, time: .shortened))")
                lines.append("- Type: \(event.kind.displayName)")
                lines.append("- Status: \(event.status.displayName)")
                if let url = event.urls.first { lines.append("- URL: \(url.absoluteString)") }
                lines.append("")
                lines.append(event.summary)
                if !event.details.isEmpty { lines += ["", event.details] }
                lines.append("")
            }
            if !commitments.isEmpty {
                lines += ["# Follow Up", ""]
                for commitment in commitments {
                    lines.append("- [\(commitment.state == .completed ? "x" : " ")] \(commitment.action) — \(commitment.state.displayName)")
                }
            }
            return Data(lines.joined(separator: "\n").utf8)
        }
    }

    @MainActor
    static func save(_ data: Data, format: ExportFormat) throws -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export Iriz Journal"
        panel.nameFieldStringValue = "Iriz Journal.\(format.rawValue == "json" ? "json" : "md")"
        panel.canCreateDirectories = true
        panel.message = "This export is not encrypted. Store it somewhere private. Raw screenshots and audio are not included."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
}
