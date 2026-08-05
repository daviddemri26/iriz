import SwiftUI

struct FloatingCapsuleView: View {
    @ObservedObject var model: FloatingCapsuleModel
    @EnvironmentObject private var app: AppState

    var body: some View {
        Group {
            if model.isExpanded { expandedView } else { collapsedView }
        }
        .animation(.snappy(duration: 0.28), value: model.isExpanded)
        .onHover(perform: model.hover)
    }

    private var collapsedView: some View {
        IrizIndicatorView(
            presentation: app.indicatorPresentation,
            logoSize: IrizIndicatorMetrics.logoSize
        )
        .frame(
            width: IrizIndicatorMetrics.collapsedPanelSize,
            height: IrizIndicatorMetrics.collapsedPanelSize
        )
        .contentShape(
            RoundedRectangle(
                cornerRadius: IrizIndicatorMetrics.logoSize * IrizIndicatorMetrics.logoCornerRadiusRatio
                    + IrizIndicatorMetrics.ringOutset,
                style: .continuous
            )
        )
        .help("Iriz · \(app.indicatorPresentation.title)")
        .onTapGesture(perform: model.expand)
        .simultaneousGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { _ in model.dragChanged() }
                .onEnded { _ in model.dragEnded() }
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens Iriz controls")
        .accessibilityAction(.default) { model.expand() }
    }

    private var expandedView: some View {
        ObservationControlCard(
            placement: .floating,
            dragChanged: model.dragChanged,
            dragEnded: model.dragEnded,
            interactionChanged: model.setInteractionActive
        )
        .overlay {
            if !model.actionsEnabled {
                Color.clear.contentShape(Rectangle())
            }
        }
    }
}
