@preconcurrency import AppKit
import SwiftUI

enum IrizTheme {
    static let ink = Color(red: 0.08, green: 0.10, blue: 0.14)
    static let muted = Color(red: 0.42, green: 0.45, blue: 0.52)
    static let violet = Color(red: 0.42, green: 0.30, blue: 0.92)
    static let coral = Color(red: 0.96, green: 0.42, blue: 0.47)
    static let mint = Color(red: 0.20, green: 0.72, blue: 0.62)
    static let observing = Color(red: 0.16, green: 0.52, blue: 0.96)
    static let listening = Color(red: 0.92, green: 0.30, blue: 0.64)
    static let observingAndListening = Color(red: 0.30, green: 0.36, blue: 0.86)
    static let processing = Color(red: 0.94, green: 0.60, blue: 0.16)
    static let attention = Color.orange
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let gradient = LinearGradient(colors: [violet, coral], startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension FollowUpColorToken {
    var color: Color {
        switch self {
        case .violet: IrizTheme.violet
        case .indigo: Color.indigo
        case .blue: Color.blue
        case .teal: Color.teal
        case .mint: IrizTheme.mint
        case .green: Color.green
        case .yellow: Color.yellow
        case .orange: Color.orange
        case .coral: IrizTheme.coral
        case .pink: Color.pink
        case .plum: Color(red: 0.58, green: 0.22, blue: 0.55)
        case .brown: Color.brown
        }
    }
}

struct IrizLogo: View {
    enum Shape {
        case appIcon
        case circle
    }

    var size: CGFloat = 34
    var shape: Shape = .appIcon
    var castsShadow = true

    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .scaledToFill()
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: shape == .circle ? size / 2 : size * 0.24, style: .continuous))
        .shadow(
            color: castsShadow ? IrizTheme.violet.opacity(0.22) : .clear,
            radius: castsShadow ? size * 0.15 : 0,
            y: castsShadow ? size * 0.06 : 0
        )
        .accessibilityLabel("Iriz")
    }
}

struct SoftCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .background(IrizTheme.card.opacity(0.76), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.06)))
    }
}
