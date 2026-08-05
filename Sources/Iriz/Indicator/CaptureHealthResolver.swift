import Foundation

struct CaptureHealthInputs: Sendable {
    var settings: IrizSettings
    var secureStorageState: SecureStorageState
    var apiKeyState: APIKeyState
    var screenPermission: PermissionState
    var accessibilityPermission: PermissionState
    var microphonePermission: PermissionState
    var screenFailureMessage: String?
    var audioFailureMessage: String?
    var screenVisibility: ScreenContextVisibility
    var meetingContextDetected: Bool
    var now: Date
}

enum CaptureHealthResolver {
    static func resolve(_ input: CaptureHealthInputs) -> CaptureHealth {
        switch input.secureStorageState {
        case .needsApproval:
            return .permissionNeeded("Keychain access")
        case .unavailable:
            return .error("Secure storage needs attention.")
        case .checking:
            return .paused
        case .ready:
            break
        }

        switch input.apiKeyState {
        case .needsApproval:
            return .permissionNeeded("Keychain access")
        case .invalid:
            return .error("OpenAI credentials need attention.")
        case .checking, .missing, .saved, .testing, .valid:
            break
        }

        let settings = input.settings
        guard !settings.isPaused else { return .paused }
        if settings.captureTiming == .schedule,
           !settings.isCaptureWindowActive(at: input.now) {
            return (settings.screenCaptureEnabled || settings.isListenEnabled)
                ? .waitingForSchedule
                : .paused
        }

        if settings.isScreenCaptureActiveNow {
            if input.screenPermission != .granted {
                return .permissionNeeded("Screen Recording")
            }
            if input.accessibilityPermission != .granted {
                return .permissionNeeded("Accessibility")
            }
            if let screenFailureMessage = input.screenFailureMessage {
                return .error(screenFailureMessage)
            }
        }

        if settings.isAudioActiveNow {
            if input.microphonePermission != .granted {
                return .permissionNeeded("Microphone")
            }
            if let audioFailureMessage = input.audioFailureMessage {
                return .error(audioFailureMessage)
            }
        }

        if settings.meetingDetectionEnabled,
           settings.isScreenCaptureActiveNow,
           input.screenVisibility == .available,
           input.meetingContextDetected {
            return settings.isAudioActiveNow ? .meetingAndListening : .meeting
        }
        if settings.isAudioActiveNow {
            return settings.isScreenCaptureActiveNow ? .observingAndListening : .listening
        }
        if settings.isScreenCaptureActiveNow { return .observing }
        return .paused
    }
}
