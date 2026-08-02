@preconcurrency import AppKit
@preconcurrency import AVFoundation
@preconcurrency import ApplicationServices
import Combine
import CoreGraphics
import Foundation
import UserNotifications

enum PermissionState: Equatable, Sendable {
    case notDetermined
    case denied
    case granted
}

enum IrizPermission: CaseIterable, Equatable, Sendable {
    case screenRecording
    case microphone
    case accessibility
    case notifications
}

struct PermissionSnapshot: Equatable, Sendable {
    var screenRecording: PermissionState = .notDetermined
    var microphone: PermissionState = .notDetermined
    var accessibility: PermissionState = .notDetermined
    var notifications: PermissionState = .notDetermined

    subscript(permission: IrizPermission) -> PermissionState {
        switch permission {
        case .screenRecording: screenRecording
        case .microphone: microphone
        case .accessibility: accessibility
        case .notifications: notifications
        }
    }
}

enum PermissionService {
    private static let screenRequestedKey = "iriz.permission.screen-recording.requested"
    private static let accessibilityRequestedKey = "iriz.permission.accessibility.requested"

    static func screenCaptureState(defaults: UserDefaults = .standard) -> PermissionState {
        inferredState(
            isGranted: CGPreflightScreenCaptureAccess(),
            wasRequested: defaults.bool(forKey: screenRequestedKey)
        )
    }

    static func requestScreenCapture(defaults: UserDefaults = .standard) -> Bool {
        defaults.set(true, forKey: screenRequestedKey)
        return CGRequestScreenCaptureAccess()
    }

    static func microphoneState() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func accessibilityState(defaults: UserDefaults = .standard) -> PermissionState {
        inferredState(
            isGranted: AXIsProcessTrusted(),
            wasRequested: defaults.bool(forKey: accessibilityRequestedKey)
        )
    }

    static func requestAccessibility(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: accessibilityRequestedKey)
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func requestNotifications() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge])) ?? false
    }

    static func notificationsState() async -> PermissionState {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: .granted
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    static func inferredState(isGranted: Bool, wasRequested: Bool) -> PermissionState {
        if isGranted { return .granted }
        return wasRequested ? .denied : .notDetermined
    }

    static func openSystemSettings(for permission: IrizPermission) {
        let pane = switch permission {
        case .screenRecording: "com.apple.preference.security?Privacy_ScreenCapture"
        case .microphone: "com.apple.preference.security?Privacy_Microphone"
        case .accessibility: "com.apple.preference.security?Privacy_Accessibility"
        case .notifications: "com.apple.Notifications-Settings.extension"
        }
        guard let url = URL(string: "x-apple.systempreferences:\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}

@MainActor
final class PermissionMonitor: ObservableObject {
    @Published private(set) var snapshot = PermissionSnapshot()
    @Published private(set) var isRefreshing = false
    @Published private(set) var requestedPermission: IrizPermission?

    func monitor() async {
        await refresh()
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    func refresh() async {
        isRefreshing = true
        let notifications = await PermissionService.notificationsState()
        snapshot = PermissionSnapshot(
            screenRecording: PermissionService.screenCaptureState(),
            microphone: PermissionService.microphoneState(),
            accessibility: PermissionService.accessibilityState(),
            notifications: notifications
        )
        isRefreshing = false
    }

    func request(_ permission: IrizPermission) async {
        guard requestedPermission == nil else { return }
        requestedPermission = permission
        defer { requestedPermission = nil }
        if snapshot[permission] == .denied {
            PermissionService.openSystemSettings(for: permission)
            return
        }
        switch permission {
        case .screenRecording:
            _ = PermissionService.requestScreenCapture()
        case .microphone:
            _ = await PermissionService.requestMicrophone()
        case .accessibility:
            PermissionService.requestAccessibility()
        case .notifications:
            _ = await PermissionService.requestNotifications()
        }
        await refresh()
    }
}
