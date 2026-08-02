@preconcurrency import AppKit
import Combine
import SwiftUI

@MainActor
final class FloatingCapsuleModel: ObservableObject {
    @Published var isExpanded = false
    @Published private(set) var isDragging = false
    @Published private(set) var actionsEnabled = false
    var resize: ((Bool) -> Void)?
    var beginDrag: ((NSPoint) -> Void)?
    var updateDrag: ((NSPoint) -> Void)?
    var endDrag: (() -> Void)?
    private var openTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var actionsTask: Task<Void, Never>?
    private var isPointerInside = false
    private var isInteractionActive = false

    func hover(_ inside: Bool) {
        isPointerInside = inside
        openTask?.cancel()
        closeTask?.cancel()
        if inside {
            guard !isDragging else { return }
            guard !isExpanded else { return }
            openTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled, let self, self.isPointerInside, !self.isDragging else { return }
                isExpanded = true
                resize?(true)
                actionsTask?.cancel()
                actionsTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(240))
                    guard !Task.isCancelled else { return }
                    self?.actionsEnabled = true
                }
            }
        } else {
            closeTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(550))
                guard !Task.isCancelled, let self, !self.isInteractionActive, !self.isDragging else { return }
                self.actionsTask?.cancel()
                self.actionsEnabled = false
                self.isExpanded = false
                self.resize?(false)
            }
        }
    }

    func dragChanged() {
        let point = NSEvent.mouseLocation
        if !isDragging {
            openTask?.cancel()
            closeTask?.cancel()
            isDragging = true
            beginDrag?(point)
        }
        updateDrag?(point)
    }

    func dragEnded() {
        guard isDragging else { return }
        isDragging = false
        endDrag?()
        hover(isPointerInside)
    }

    func setInteractionActive(_ active: Bool) {
        isInteractionActive = active
        if active {
            closeTask?.cancel()
        } else if !isPointerInside {
            hover(false)
        }
    }
}

@MainActor
final class FloatingPanelController {
    private enum DockEdge: String {
        case left
        case right
    }

    private let panel: FloatingPanel
    private let model = FloatingCapsuleModel()
    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var dockEdge: DockEdge = .right
    private let collapsed = NSSize(width: 52, height: 52)
    private let expanded = NSSize(
        width: ObservationControlMetrics.floatingWidth,
        height: ObservationControlMetrics.cardHeight
    )
    private let edgeInset: CGFloat = 12

    init(app: AppState, settings: SettingsStore) {
        panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: collapsed),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .utilityWindow
        panel.isExcludedFromWindowsMenu = true
        let hostingView = NSHostingView(rootView: FloatingCapsuleView(model: model)
            .environmentObject(app)
            .environmentObject(settings))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView

        model.resize = { [weak self] expanded in self?.resize(expanded: expanded) }
        model.beginDrag = { [weak self] point in self?.beginDrag(at: point) }
        model.updateDrag = { [weak self] point in self?.updateDrag(to: point) }
        model.endDrag = { [weak self] in self?.finishDrag() }
        restorePosition()
    }

    func show() {
        panel.orderFrontRegardless()
    }

    private func resize(expanded isExpanded: Bool) {
        let size = isExpanded ? expanded : collapsed
        let old = panel.frame
        guard abs(old.width - size.width) > 0.5 || abs(old.height - size.height) > 0.5 else { return }
        guard let screen = bestScreen(for: old) else { return }
        let bounds = screen.visibleFrame
        var origin = NSPoint(
            x: dockEdge == .left ? bounds.minX + edgeInset : bounds.maxX - size.width - edgeInset,
            y: old.midY - size.height / 2
        )
        origin.y = clampedY(origin.y, height: size.height, in: bounds)
        panel.hasShadow = isExpanded
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: true)
    }

    private func beginDrag(at point: NSPoint) {
        dragStartMouse = point
        dragStartOrigin = panel.frame.origin
    }

    private func updateDrag(to point: NSPoint) {
        guard let mouse = dragStartMouse, let origin = dragStartOrigin else { return }
        panel.setFrameOrigin(NSPoint(
            x: origin.x + point.x - mouse.x,
            y: origin.y + point.y - mouse.y
        ))
    }

    private func finishDrag() {
        dragStartMouse = nil
        dragStartOrigin = nil
        snapToEdge()
    }

    private func snapToEdge() {
        guard let screen = bestScreen(for: panel.frame) else { return }
        let bounds = screen.visibleFrame
        var frame = panel.frame
        dockEdge = frame.midX < bounds.midX ? .left : .right
        frame.origin.x = dockEdge == .left ? bounds.minX + edgeInset : bounds.maxX - frame.width - edgeInset
        frame.origin.y = clampedY(frame.origin.y, height: frame.height, in: bounds)
        panel.setFrame(frame, display: true, animate: true)
        savePosition(screen: screen)
    }

    private func screenIdentifier(_ screen: NSScreen) -> String {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "main"
    }

    private func screenKey(_ screen: NSScreen) -> String {
        "iriz.floating.position.\(screenIdentifier(screen))"
    }

    private func savePosition(screen: NSScreen) {
        let bounds = screen.visibleFrame
        let verticalRatio = min(max((panel.frame.midY - bounds.minY) / max(bounds.height, 1), 0), 1)
        let key = screenKey(screen)
        UserDefaults.standard.set(dockEdge.rawValue, forKey: "\(key).edge")
        UserDefaults.standard.set(Double(verticalRatio), forKey: "\(key).verticalRatio")
        UserDefaults.standard.set(screenIdentifier(screen), forKey: "iriz.floating.lastScreen")
    }

    private func restorePosition() {
        let lastScreen = UserDefaults.standard.string(forKey: "iriz.floating.lastScreen")
        let screen = NSScreen.screens.first(where: { screenIdentifier($0) == lastScreen }) ?? NSScreen.main ?? NSScreen.screens[0]
        let bounds = screen.visibleFrame
        let key = screenKey(screen)
        if let savedEdge = UserDefaults.standard.string(forKey: "\(key).edge"), let edge = DockEdge(rawValue: savedEdge) {
            dockEdge = edge
        } else {
            let legacy = UserDefaults.standard.array(forKey: key) as? [NSNumber]
            dockEdge = (legacy?.first?.doubleValue ?? Double(bounds.midX)) < Double(bounds.midX) ? .left : .right
        }
        let ratioKey = "\(key).verticalRatio"
        let ratio = UserDefaults.standard.object(forKey: ratioKey) == nil ? 0.5 : UserDefaults.standard.double(forKey: ratioKey)
        let x = dockEdge == .left ? bounds.minX + edgeInset : bounds.maxX - collapsed.width - edgeInset
        let proposedY = bounds.minY + bounds.height * ratio - collapsed.height / 2
        let origin = NSPoint(x: x, y: clampedY(proposedY, height: collapsed.height, in: bounds))
        panel.setFrame(NSRect(origin: origin, size: collapsed), display: false)
    }

    private func clampedY(_ y: CGFloat, height: CGFloat, in bounds: NSRect) -> CGFloat {
        min(max(y, bounds.minY + edgeInset), bounds.maxY - height - edgeInset)
    }

    private func bestScreen(for frame: NSRect) -> NSScreen? {
        NSScreen.screens.max { lhs, rhs in
            lhs.visibleFrame.intersection(frame).area < rhs.visibleFrame.intersection(frame).area
        } ?? NSScreen.main
    }
}

private extension NSRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
