import Foundation
import SwiftUI

enum IndicatorColorToken: String, Hashable, Sendable {
    case neutral
    case privateContext
    case observing
    case listening
    case meeting
    case violet
    case mint
    case attention
    case apiHighlight
    case apiWarmHighlight
    case voiceSignalHighlight
    case indigo

    @MainActor
    var color: Color {
        switch self {
        case .neutral: Color.secondary
        case .privateContext: IrizTheme.privateContext
        case .observing: IrizTheme.observing
        case .listening: IrizTheme.listening
        case .meeting: IrizTheme.coral
        case .violet: IrizTheme.violet
        case .mint: IrizTheme.mint
        case .attention: IrizTheme.attention
        case .apiHighlight: IrizTheme.apiHighlight
        case .apiWarmHighlight: IrizTheme.apiWarmHighlight
        case .voiceSignalHighlight: IrizTheme.voiceSignalHighlight
        case .indigo: IrizTheme.observingAndListening
        }
    }
}

struct IndicatorPalette: Equatable, Sendable {
    let tokens: [IndicatorColorToken]

    init(_ tokens: [IndicatorColorToken]) {
        var seen = Set<IndicatorColorToken>()
        self.tokens = tokens.filter { seen.insert($0).inserted }
    }

    func merging(_ other: IndicatorPalette) -> IndicatorPalette {
        IndicatorPalette(tokens + other.tokens)
    }

    @MainActor
    var colors: [Color] { tokens.map(\.color) }

    static let neutral = IndicatorPalette([.neutral])
    static let privateContext = IndicatorPalette([.privateContext])
    static let privateListening = IndicatorPalette([.privateContext, .listening])
    static let observing = IndicatorPalette([.observing])
    static let listening = IndicatorPalette([.listening])
    static let observingAndListening = IndicatorPalette([.observing, .listening])
    static let meeting = IndicatorPalette([.observing, .meeting])
    static let meetingAndListening = IndicatorPalette([.observing, .meeting, .listening])
    static let violet = IndicatorPalette([.violet])
    static let mint = IndicatorPalette([.mint])
    static let attention = IndicatorPalette([.attention])
    static let screenSignal = IndicatorPalette([.observing, .apiHighlight])
    static let voiceSignal = IndicatorPalette([.listening, .voiceSignalHighlight])
    static let meetingSignal = IndicatorPalette([.observing, .meeting, .apiWarmHighlight])
    static let violetSignal = IndicatorPalette([.violet, .apiHighlight])
    static let screenAPI = IndicatorPalette([.observing, .apiHighlight, .indigo])
    static let speechAPI = IndicatorPalette([.listening, .meeting, .violet])
    static let meetingAPI = IndicatorPalette([.meeting, .apiWarmHighlight, .listening])
    static let intensiveAPI = IndicatorPalette([.violet, .listening, .indigo])
}

struct IndicatorPresentation: Equatable, Sendable {
    enum Motion: Equatable, Sendable {
        case fixed
        case api(rotationDuration: TimeInterval)
    }

    let title: String
    let detail: String
    let symbol: String
    let palette: IndicatorPalette
    let badge: String
    let motion: Motion
    var modelName: String?
    var accessibilityActivity: String?

    init(
        title: String,
        detail: String,
        symbol: String,
        palette: IndicatorPalette,
        badge: String,
        motion: Motion,
        modelName: String? = nil,
        accessibilityActivity: String? = nil
    ) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.palette = palette
        self.badge = badge
        self.motion = motion
        self.modelName = modelName
        self.accessibilityActivity = accessibilityActivity
    }

    @MainActor
    var tint: Color { palette.colors.first ?? Color.secondary }

    var rotates: Bool {
        if case .api = motion { return true }
        return false
    }

    var accessibilityLabel: String {
        var components = ["Iriz", title]
        if let accessibilityActivity, !accessibilityActivity.isEmpty {
            components.append(accessibilityActivity)
        }
        if let modelName, !modelName.isEmpty {
            components.append("Model \(modelName)")
        }
        return components.joined(separator: ", ")
    }
}

enum IndicatorAnnouncementPolicy {
    static func announcement(
        previous: IndicatorPresentation?,
        next: IndicatorPresentation
    ) -> String? {
        guard let previous else { return nil }
        guard previous.accessibilityLabel != next.accessibilityLabel
                || previous.detail != next.detail else { return nil }
        return "\(next.accessibilityLabel). \(next.detail)"
    }
}

extension CaptureHealth {
    /// Compatibility presentation for durable capture health. Transient work is
    /// resolved from the indicator activity snapshot instead of mutating this state.
    var irizAppearance: IndicatorPresentation {
        switch self {
        case .paused:
            IndicatorPresentation(
                title: "Iriz is paused",
                detail: "Nothing is being captured.",
                symbol: "moon.zzz.fill",
                palette: .neutral,
                badge: "PAUSED",
                motion: .fixed
            )
        case .observing:
            IndicatorPresentation(
                title: "Iriz is observing",
                detail: "The screen is active right now.",
                symbol: "eye.fill",
                palette: .observing,
                badge: "LIVE",
                motion: .fixed
            )
        case .listening:
            IndicatorPresentation(
                title: "Iriz is listening",
                detail: "The microphone is active right now.",
                symbol: "waveform",
                palette: .listening,
                badge: "LIVE",
                motion: .fixed
            )
        case .observingAndListening:
            IndicatorPresentation(
                title: "Iriz is observing and listening",
                detail: "Screen and microphone are active right now.",
                symbol: "eye.fill",
                palette: .observingAndListening,
                badge: "LIVE",
                motion: .fixed
            )
        case .waitingForSchedule:
            IndicatorPresentation(
                title: "Iriz is waiting",
                detail: "Not observing or listening right now.",
                symbol: "clock.fill",
                palette: .neutral,
                badge: "WAITING",
                motion: .fixed
            )
        case .meeting:
            IndicatorPresentation(
                title: "Meeting detected",
                detail: "Keeping context from this meeting.",
                symbol: "person.2.fill",
                palette: .meeting,
                badge: "MEETING",
                motion: .fixed
            )
        case .meetingAndListening:
            IndicatorPresentation(
                title: "Meeting detected · listening",
                detail: "Meeting context and the microphone are active right now.",
                symbol: "person.2.fill",
                palette: .meetingAndListening,
                badge: "MEETING",
                motion: .fixed
            )
        case .processing:
            IndicatorPresentation(
                title: "A useful signal stood out",
                detail: "Iriz retained meaningful local context.",
                symbol: "sparkles",
                palette: .observing,
                badge: "SIGNAL",
                motion: .fixed
            )
        case .permissionNeeded(let permission):
            IndicatorPresentation(
                title: "Permission needed",
                detail: "Enable \(permission) to restore context.",
                symbol: "lock.trianglebadge.exclamationmark.fill",
                palette: .attention,
                badge: "CHECK",
                motion: .fixed
            )
        case .error:
            IndicatorPresentation(
                title: "Iriz needs attention",
                detail: "Open Settings to review the issue.",
                symbol: "exclamationmark.triangle.fill",
                palette: .attention,
                badge: "CHECK",
                motion: .fixed
            )
        }
    }
}
