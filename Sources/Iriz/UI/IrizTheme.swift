@preconcurrency import AppKit
import SwiftUI

enum IrizTheme {
    static let ink = Color(red: 0.08, green: 0.10, blue: 0.14)
    static let muted = Color(red: 0.42, green: 0.45, blue: 0.52)
    static let violet = Color(red: 0.42, green: 0.30, blue: 0.92)
    static let coral = Color(red: 0.96, green: 0.42, blue: 0.47)
    static let mint = Color(red: 0.20, green: 0.72, blue: 0.62)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let gradient = LinearGradient(colors: [violet, coral], startPoint: .topLeading, endPoint: .bottomTrailing)
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
