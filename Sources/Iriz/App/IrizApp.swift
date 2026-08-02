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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        floatingPanel = FloatingPanelController(app: .shared, settings: .shared)
        floatingPanel?.show()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
