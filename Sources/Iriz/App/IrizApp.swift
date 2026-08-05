@preconcurrency import AppKit
import Combine
import SwiftUI

@main
struct IrizApp: App {
    @NSApplicationDelegateAdaptor(IrizAppDelegate.self) private var delegate
    @StateObject private var app = AppState.shared
    @StateObject private var settings = SettingsStore.shared

    var body: some Scene {
        Window("iriz", id: "main") {
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
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                Button(settings.settings.isPaused ? "Resume iriz" : "Pause iriz") {
                    app.setPaused(!settings.settings.isPaused)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Ask iriz") { app.openMainWindow(section: .assistant) }
                    .keyboardShortcut("k", modifiers: [.command])
            }
        }
    }
}

enum MainWindowPresentationPolicy {
    static let allowsMultipleMainWindows = false

    static func targetFrame(for visibleFrame: CGRect) -> CGRect {
        visibleFrame
    }
}

@MainActor
final class IrizAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var floatingPanel: FloatingPanelController?
    private var menuBarController: MenuBarController?
    private var mainWindow: NSWindow?
    private var floatingVisibilityCancellable: AnyCancellable?
    private var floatingBubbleEnabled = SettingsStore.shared.settings.showFloatingBubble
    private var mainWindowPresented = true

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
            .sink { [weak self] isEnabled in
                self?.floatingBubbleEnabled = isEnabled
                self?.updateFloatingVisibility()
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
        if let mainWindow, mainWindow !== window {
            window.orderOut(nil)
            window.close()
            maximize(mainWindow)
            mainWindow.makeKeyAndOrderFront(nil)
            return
        }

        mainWindow = window
        window.delegate = self
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.minSize = NSSize(width: 900, height: 620)
        mainWindowPresented = window.isVisible
        updateFloatingVisibility()
        maximize(window)
    }

    private func showMainWindow() {
        mainWindowPresented = true
        updateFloatingVisibility()
        NSApp.activate(ignoringOtherApps: true)
        if let mainWindow {
            maximize(mainWindow)
            mainWindow.makeKeyAndOrderFront(nil)
            return
        }

        // The singleton SwiftUI Window scene is created during launch. If its
        // resolver has not attached yet, wait for it instead of synthesizing a
        // New Window command that could create a second, smaller window.
        DispatchQueue.main.async { [weak self] in
            guard let self, let mainWindow = self.mainWindow else { return }
            self.maximize(mainWindow)
            mainWindow.makeKeyAndOrderFront(nil)
        }
    }

    private func maximize(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        window.setFrame(
            MainWindowPresentationPolicy.targetFrame(for: screen.visibleFrame),
            display: true
        )
    }

    @objc private func openMainWindowRequested(_ notification: Notification) {
        showMainWindow()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === mainWindow else { return }
        mainWindowPresented = false
        updateFloatingVisibility()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === mainWindow else { return }
        mainWindowPresented = true
        updateFloatingVisibility()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === mainWindow else { return }
        mainWindowPresented = true
        maximize(window)
        updateFloatingVisibility()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === mainWindow else { return }
        mainWindowPresented = true
        maximize(window)
        updateFloatingVisibility()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === mainWindow else { return }
        maximize(window)
        updateFloatingVisibility()
    }

    private func updateFloatingVisibility() {
        floatingPanel?.setVisible(FloatingVisibilityPolicy.shouldShow(
            settingEnabled: floatingBubbleEnabled,
            mainWindowPresented: mainWindowPresented
        ))
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
