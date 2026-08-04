@preconcurrency import AppKit
import Combine

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let app: AppState
    private let settings: SettingsStore
    private var statusItem: NSStatusItem?
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

        app.$captureHealth
            .sink { [weak self] _ in
                self?.updateButtonDescription()
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
        item.button?.setAccessibilityLabel("Iriz")
        let menu = NSMenu(title: "Iriz")
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

        let status = NSMenuItem(title: app.captureHealth.irizAppearance.title, action: nil, keyEquivalent: "")
        status.image = NSImage(systemSymbolName: app.captureHealth.irizAppearance.symbol, accessibilityDescription: nil)
        status.isEnabled = false
        menu.addItem(status)

        let detail = NSMenuItem(title: app.captureHealth.irizAppearance.detail, action: nil, keyEquivalent: "")
        detail.isEnabled = false
        menu.addItem(detail)
        menu.addItem(.separator())

        menu.addItem(actionItem(
            title: settings.settings.isPaused ? "Resume Iriz" : "Pause Iriz",
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
        menu.addItem(actionItem(title: "Open Journal", symbol: "clock.arrow.circlepath", action: #selector(openJournal)))
        menu.addItem(actionItem(title: "Open Follow Up", symbol: "checklist", action: #selector(openFollowUp)))
        menu.addItem(actionItem(title: "Ask Iriz", symbol: "sparkles", action: #selector(openAssistant)))
        menu.addItem(.separator())
        menu.addItem(actionItem(title: "Settings…", symbol: "gearshape", action: #selector(openSettings)))
        menu.addItem(actionItem(title: "Quit Iriz", symbol: "power", action: #selector(quit)))
    }

    private func actionItem(title: String, symbol: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    private func updateButtonDescription() {
        statusItem?.button?.toolTip = "Iriz · \(app.captureHealth.displayName)"
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

    @objc private func openJournal() {
        app.openMainWindow(section: .journal)
    }

    @objc private func openFollowUp() {
        app.openMainWindow(section: .followUp)
    }

    @objc private func openAssistant() {
        app.openMainWindow(section: .assistant)
    }

    @objc private func openSettings() {
        app.openMainWindow(section: .settings)
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
