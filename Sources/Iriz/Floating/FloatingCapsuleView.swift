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
        IrizBreathingLogo(size: 46)
        .frame(width: 52, height: 52)
        .contentShape(Circle())
        .help("Iriz · \(app.captureHealth.irizAppearance.title)")
        .simultaneousGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { _ in model.dragChanged() }
                .onEnded { _ in model.dragEnded() }
        )
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
