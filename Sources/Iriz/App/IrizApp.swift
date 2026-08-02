@preconcurrency import AppKit
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
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Open Journal") { app.openMainWindow(section: .journal) }
                    .keyboardShortcut("j", modifiers: [.command, .shift])
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
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mainWindowDidBecomeMain(_:)),
            name: NSWindow.didBecomeMainNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openMainWindowRequested(_:)),
            name: .irizOpenMainWindow,
            object: nil
        )
        floatingPanel = FloatingPanelController(app: .shared, settings: .shared)
        floatingPanel?.show()
        DispatchQueue.main.async { [weak self] in
            guard let window = NSApp.windows.first(where: { !($0 is NSPanel) }) else { return }
            self?.retainMainWindow(window)
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

    private func retainMainWindow(_ window: NSWindow) {
        mainWindow = window
        window.isReleasedWhenClosed = false
        window.isRestorable = false
    }

    private func showMainWindow() {
        if mainWindow == nil, let window = NSApp.windows.first(where: { !($0 is NSPanel) }) {
            retainMainWindow(window)
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func mainWindowDidBecomeMain(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, !(window is NSPanel) else { return }
        retainMainWindow(window)
    }

    @objc private func openMainWindowRequested(_ notification: Notification) {
        showMainWindow()
    }
}

extension Notification.Name {
    static let irizOpenMainWindow = Notification.Name("com.iriz.memory.open-main-window")
}
