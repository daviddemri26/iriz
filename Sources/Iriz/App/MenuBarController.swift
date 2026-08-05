@preconcurrency import AppKit
import Combine

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let app: AppState
    private let settings: SettingsStore
    private var statusItem: NSStatusItem?
    private var previousPresentation: IndicatorPresentation?
    private var cancellables = Set<AnyCancellable>()

    init(app: AppState, settings: SettingsStore) {
        self.app = app
        self.settings = settings
        super.init()

        settings.$settings
            .map(\.showMenuBarItem)
            .removeDuplicates()
            .sink { [weak self] isVisible in
                self?.setVisible(isVisible)
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(app.$captureHealth, app.$indicatorSnapshot)
            .map { captureHealth, snapshot in
                IndicatorPresentationResolver.resolve(
                    captureHealth: captureHealth,
                    snapshot: snapshot
                )
            }
            .removeDuplicates()
            .sink { [weak self] presentation in
                self?.presentationDidChange(presentation)
            }
            .store(in: &cancellables)
    }

    private func setVisible(_ isVisible: Bool) {
        if isVisible {
            installStatusItemIfNeeded()
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    private func installStatusItemIfNeeded() {
        guard statusItem == nil else {
            updateButtonDescription()
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.flatLogoImage()
        item.button?.imagePosition = .imageOnly
        item.button?.setAccessibilityLabel("iriz")
        let menu = NSMenu(title: "iriz")
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateButtonDescription()
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu(menu)
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let presentation = app.indicatorPresentation
        let status = NSMenuItem(title: presentation.title, action: nil, keyEquivalent: "")
        status.image = NSImage(systemSymbolName: presentation.symbol, accessibilityDescription: nil)
        status.isEnabled = false
        menu.addItem(status)

        let detail = NSMenuItem(title: presentation.detail, action: nil, keyEquivalent: "")
        detail.isEnabled = false
        menu.addItem(detail)

        if let modelName = presentation.modelName {
            let model = NSMenuItem(title: "Model · \(modelName)", action: nil, keyEquivalent: "")
            model.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: nil)
            model.isEnabled = false
            menu.addItem(model)
        }
        menu.addItem(.separator())

        menu.addItem(actionItem(
            title: settings.settings.isPaused ? "Resume iriz" : "Pause iriz",
            symbol: settings.settings.isPaused ? "play.fill" : "pause.fill",
            action: #selector(togglePause)
        ))
        let observe = actionItem(title: "Observe Screen", symbol: "eye.fill", action: #selector(toggleObserve))
        observe.state = app.isObserveEnabled ? .on : .off
        menu.addItem(observe)
        let listen = actionItem(title: "Listen", symbol: "waveform", action: #selector(toggleListen))
        listen.state = app.isListenEnabled ? .on : .off
        menu.addItem(listen)

        let bubble = actionItem(title: "Floating Bubble", symbol: "circle.circle", action: #selector(toggleFloatingBubble))
        bubble.state = settings.settings.showFloatingBubble ? .on : .off
        menu.addItem(bubble)
        menu.addItem(.separator())

        menu.addItem(actionItem(title: "Mark Moment", symbol: "bookmark.fill", action: #selector(markMoment)))
        menu.addItem(actionItem(title: "Open Actions", symbol: "checklist", action: #selector(openFollowUp)))
        menu.addItem(actionItem(title: "Ask iriz", symbol: "sparkles", action: #selector(openAssistant)))
        menu.addItem(.separator())
        menu.addItem(actionItem(title: "Settings…", symbol: "gearshape", action: #selector(openSettings)))
        menu.addItem(actionItem(title: "Quit iriz", symbol: "power", action: #selector(quit)))
    }

    private func actionItem(title: String, symbol: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    private func updateButtonDescription() {
        updateButtonDescription(using: app.indicatorPresentation)
    }

    private func updateButtonDescription(using presentation: IndicatorPresentation) {
        statusItem?.button?.toolTip = presentation.accessibilityLabel
        statusItem?.button?.setAccessibilityLabel(presentation.accessibilityLabel)
        statusItem?.button?.setAccessibilityHelp(presentation.detail)
    }

    private func presentationDidChange(_ presentation: IndicatorPresentation) {
        updateButtonDescription(using: presentation)
        let announcement = IndicatorAnnouncementPolicy.announcement(
            previous: previousPresentation,
            next: presentation
        )
        previousPresentation = presentation
        guard let announcement, NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }

    @objc private func togglePause() {
        app.setPaused(!settings.settings.isPaused)
    }

    @objc private func toggleObserve() {
        app.setObserveEnabled(!app.isObserveEnabled)
    }

    @objc private func toggleListen() {
        app.setListenEnabled(!app.isListenEnabled)
    }

    @objc private func toggleFloatingBubble() {
        settings.settings.showFloatingBubble.toggle()
    }

    @objc private func markMoment() {
        Task { await app.markMoment() }
    }

    @objc private func openFollowUp() {
        app.openMainWindow(section: .followUp)
    }

    @objc private func openAssistant() {
        app.openMainWindow(section: .assistant)
    }

    @objc private func openSettings() {
        app.openSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private static func flatLogoImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 19, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            for oval in [
                NSRect(x: 5.5, y: 7.0, width: 8.0, height: 9.0),
                NSRect(x: 2.5, y: 2.0, width: 9.0, height: 9.0),
                NSRect(x: 8.0, y: 2.0, width: 9.0, height: 9.0)
            ] {
                let path = NSBezierPath(ovalIn: oval)
                path.lineWidth = 1.65
                path.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
