@preconcurrency import AppKit
import Combine
import SwiftUI

@main
struct IrizApp: App {
    @NSApplicationDelegateAdaptor(IrizAppDelegate.self) private var delegate
    @StateObject private var app = AppState.shared
    @StateObject private var settings = SettingsStore.shared

    var body: some Scene {
        WindowGroup("Iriz") {
            MainWindowView()
                .environmentObject(app)
                .environmentObject(settings)
                .preferredColorScheme(.dark)
                .background {
                    MainWindowResolver { window in
                        delegate.registerMainWindow(window)
                    }
                }
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(settings.settings.isPaused ? "Resume Iriz" : "Pause Iriz") {
                    app.setPaused(!settings.settings.isPaused)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Ask Iriz") { app.openMainWindow(section: .assistant) }
                    .keyboardShortcut("k", modifiers: [.command])
            }
        }
    }
}

@MainActor
final class IrizAppDelegate: NSObject, NSApplicationDelegate {
    private var floatingPanel: FloatingPanelController?
    private var menuBarController: MenuBarController?
    private var mainWindow: NSWindow?
    private var floatingVisibilityCancellable: AnyCancellable?
    private var didSizeMainWindow = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openMainWindowRequested(_:)),
            name: .irizOpenMainWindow,
            object: nil
        )
        floatingPanel = FloatingPanelController(app: .shared, settings: .shared)
        floatingVisibilityCancellable = SettingsStore.shared.$settings
            .map(\.showFloatingBubble)
            .removeDuplicates()
            .sink { [weak self] isVisible in
                self?.floatingPanel?.setVisible(isVisible)
            }
        menuBarController = MenuBarController(app: .shared, settings: .shared)
        DispatchQueue.main.async { [weak self] in
            self?.showMainWindow()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationShouldSaveSecureApplicationState(_ app: NSApplication) -> Bool { false }
    func applicationShouldRestoreSecureApplicationState(_ app: NSApplication) -> Bool { false }

    func registerMainWindow(_ window: NSWindow) {
        mainWindow = window
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        guard !didSizeMainWindow, let screen = window.screen ?? NSScreen.main else { return }
        didSizeMainWindow = true
        window.setFrame(screen.visibleFrame, display: true)
    }

    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
            return
        }

        // WindowGroup owns creation of the SwiftUI window. Reuse its standard
        // Command-N action instead of guessing among unrelated system windows.
        let newWindowItem = NSApp.mainMenu?.items
            .compactMap(\.submenu)
            .flatMap(\.items)
            .first {
                $0.keyEquivalent.lowercased() == "n" &&
                $0.keyEquivalentModifierMask.contains(.command)
            }
        if let newWindowItem, let action = newWindowItem.action {
            NSApp.sendAction(action, to: newWindowItem.target, from: newWindowItem)
        }
        DispatchQueue.main.async { [weak self] in
            self?.mainWindow?.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func openMainWindowRequested(_ notification: Notification) {
        showMainWindow()
    }
}

private struct MainWindowResolver: NSViewRepresentable {
    let resolve: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { resolve(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            if let window = nsView?.window { resolve(window) }
        }
    }
}

extension Notification.Name {
    static let irizOpenMainWindow = Notification.Name("com.iriz.memory.open-main-window")
}
