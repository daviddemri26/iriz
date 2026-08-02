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

enum IrizPermission: CaseIterable, Sendable {
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
    static func screenCaptureState() -> PermissionState {
        CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
    }

    static func requestScreenCapture() -> Bool {
        CGRequestScreenCaptureAccess()
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

    static func accessibilityState() -> PermissionState {
        AXIsProcessTrusted() ? .granted : .notDetermined
    }

    static func requestAccessibility() {
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
}

@MainActor
final class PermissionMonitor: ObservableObject {
    @Published private(set) var snapshot = PermissionSnapshot()
    @Published private(set) var isRefreshing = false

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
