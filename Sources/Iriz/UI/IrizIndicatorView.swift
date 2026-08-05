import SwiftUI

enum IrizIndicatorMetrics {
    static let logoSize: CGFloat = 46
    static let logoCornerRadiusRatio: CGFloat = 0.24
    static let logoContentScale: CGFloat = 1.20
    static let ringWidth: CGFloat = 4
    static let ringOverlap: CGFloat = 2
    static let collapsedPanelSize: CGFloat = 60
    static let ringOutset: CGFloat = ringWidth - ringOverlap

    static func scale(for logoSize: CGFloat) -> CGFloat {
        logoSize / self.logoSize
    }

    static func canvasSize(for logoSize: CGFloat) -> CGFloat {
        logoSize + ringOutset * 2 * scale(for: logoSize)
    }
}

enum IrizIndicatorAnimation {
    static func ringWidth(scale: CGFloat) -> CGFloat {
        IrizIndicatorMetrics.ringWidth * scale
    }

    static func rotationAngle(
        for motion: IndicatorPresentation.Motion,
        at time: TimeInterval,
        reduceMotion: Bool
    ) -> Double {
        guard !reduceMotion else { return 0 }
        guard case .api(let rotationDuration) = motion, rotationDuration > 0 else { return 0 }
        return (time.truncatingRemainder(dividingBy: rotationDuration) / rotationDuration) * 360
    }
}

struct IrizIndicatorView: View {
    let presentation: IndicatorPresentation
    var logoSize: CGFloat = IrizIndicatorMetrics.logoSize

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion || presentation.motion.isFixed {
                indicator(at: 0, reduceMotion: true)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                    indicator(
                        at: timeline.date.timeIntervalSinceReferenceDate,
                        reduceMotion: false
                    )
                }
            }
        }
        .frame(width: canvasSize, height: canvasSize)
        .contentShape(
            RoundedRectangle(
                cornerRadius: logoCornerRadius + ringOutset,
                style: .continuous
            )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(presentation.detail)
    }

    private var scale: CGFloat { IrizIndicatorMetrics.scale(for: logoSize) }
    private var canvasSize: CGFloat { IrizIndicatorMetrics.canvasSize(for: logoSize) }
    private var logoCornerRadius: CGFloat { logoSize * IrizIndicatorMetrics.logoCornerRadiusRatio }
    private var ringOutset: CGFloat {
        IrizIndicatorMetrics.ringOutset * scale
    }

    @MainActor
    private func indicator(at time: TimeInterval, reduceMotion: Bool) -> some View {
        let lineWidth = IrizIndicatorAnimation.ringWidth(scale: scale)
        let rotation = IrizIndicatorAnimation.rotationAngle(
            for: presentation.motion,
            at: time,
            reduceMotion: reduceMotion
        )

        return ZStack {
            IrizLogo(
                size: logoSize,
                shape: .appIcon,
                castsShadow: false,
                contentScale: IrizIndicatorMetrics.logoContentScale
            )
            ring(lineWidth: lineWidth, gradientRotation: rotation)
        }
        .frame(width: canvasSize, height: canvasSize)
    }

    @MainActor
    @ViewBuilder
    private func ring(lineWidth: CGFloat, gradientRotation: Double) -> some View {
        let overlap = IrizIndicatorMetrics.ringOverlap * scale
        let outset = lineWidth - overlap
        let shape = RoundedRectangle(
            cornerRadius: logoCornerRadius + outset,
            style: .continuous
        )
        let colors = presentation.palette.colors
        let dimensions = logoSize + outset * 2

        if colors.count > 1 {
            shape
                .strokeBorder(
                    AngularGradient(
                        colors: colors + [colors[0]],
                        center: .center,
                        startAngle: .degrees(-90 + gradientRotation),
                        endAngle: .degrees(270 + gradientRotation)
                    ),
                    lineWidth: lineWidth
                )
                .frame(width: dimensions, height: dimensions)
        } else {
            shape
                .strokeBorder(colors.first ?? Color.secondary, lineWidth: lineWidth)
                .frame(width: dimensions, height: dimensions)
        }
    }

}

private extension IndicatorPresentation.Motion {
    var isFixed: Bool {
        if case .fixed = self { return true }
        return false
    }
}
