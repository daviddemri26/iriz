import Foundation

enum AudioMode: String, Codable, CaseIterable, Sendable {
    case off
    case alwaysOn
    case schedule

    var displayName: String {
        switch self {
        case .off: "Off"
        case .alwaysOn: "Always On"
        case .schedule: "Schedule"
        }
    }
}

enum ObservationMode: String, CaseIterable, Identifiable, Sendable {
    case observe
    case listen
    case observeAndListen
    case schedule
    case paused

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .observe: "Observe"
        case .listen: "Listen"
        case .observeAndListen: "Observe + Listen"
        case .schedule: "Schedule"
        case .paused: "Paused"
        }
    }

    static func current(for settings: IrizSettings) -> ObservationMode {
        guard !settings.isPaused else { return .paused }
        return switch (settings.screenCaptureEnabled, settings.audioMode) {
        case (true, .off): .observe
        case (false, .alwaysOn): .listen
        case (true, .alwaysOn): .observeAndListen
        case (_, .schedule): .schedule
        case (false, .off): .paused
        }
    }
}

enum StructuredRetention: String, Codable, CaseIterable, Sendable {
    case thirtyDays
    case ninetyDays
    case oneYear
    case forever

    var displayName: String {
        switch self {
        case .thirtyDays: "30 days"
        case .ninetyDays: "90 days"
        case .oneYear: "1 year"
        case .forever: "Forever"
        }
    }

    var cutoffInterval: TimeInterval? {
        switch self {
        case .thirtyDays: 30 * 24 * 60 * 60
        case .ninetyDays: 90 * 24 * 60 * 60
        case .oneYear: 365 * 24 * 60 * 60
        case .forever: nil
        }
    }
}

struct AudioSchedule: Codable, Equatable, Sendable {
    var startMinutes: Int = 9 * 60
    var endMinutes: Int = 18 * 60
    var weekdays: Set<Int> = [2, 3, 4, 5, 6]

    func isActive(at date: Date, calendar: Calendar = .current) -> Bool {
        let components = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = components.weekday,
              let hour = components.hour,
              let minute = components.minute,
              weekdays.contains(weekday) else {
            return false
        }
        let value = hour * 60 + minute
        if startMinutes <= endMinutes {
            return value >= startMinutes && value < endMinutes
        }
        return value >= startMinutes || value < endMinutes
    }
}

struct IrizSettings: Codable, Equatable, Sendable {
    var hasCompletedOnboarding = false
    var isPaused = true
    var screenCaptureEnabled = true
    var audioMode: AudioMode = .off
    var audioSchedule = AudioSchedule()
    var meetingDetectionEnabled = true
    var voiceEnrollmentEnabled = false
    var outputLanguageTag = "auto"
    var structuredRetention: StructuredRetention = .forever
    var mediaRetentionHours = 24
    var dailyDigestEnabled = true
    var dailyDigestHour = 9
    var launchAtLogin = false
    var excludedBundleIdentifiers: Set<String> = ExclusionPolicy.defaultExcludedBundleIdentifiers
    var excludedDomains: Set<String> = []

    var isAudioActiveNow: Bool {
        guard !isPaused else { return false }
        return switch audioMode {
        case .off: false
        case .alwaysOn: true
        case .schedule: audioSchedule.isActive(at: Date())
        }
    }
}

enum CaptureHealth: Equatable, Sendable {
    case paused
    case observing
    case listening
    case meeting
    case processing
    case permissionNeeded(String)
    case error(String)

    var displayName: String {
        switch self {
        case .paused: "Paused"
        case .observing: "Observing"
        case .listening: "Listening"
        case .meeting: "Meeting"
        case .processing: "Processing"
        case .permissionNeeded: "Permission needed"
        case .error: "Needs attention"
        }
    }
}

enum MainSection: String, CaseIterable, Identifiable, Sendable {
    case journal = "Journal"
    case followUp = "Follow Up"
    case assistant = "Ask Iriz"
    case settings = "Settings"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .journal: "clock.arrow.circlepath"
        case .followUp: "checklist"
        case .assistant: "sparkles"
        case .settings: "gearshape"
        }
    }
}

struct LanguageOption: Identifiable, Hashable, Sendable {
    var id: String { identifier }
    var identifier: String
    var displayName: String
    var regionName: String?
    var searchableText: String

    static func allOptions(locale: Locale = Locale(identifier: "en_US")) -> [LanguageOption] {
        var seen = Set<String>()
        let options = Locale.availableIdentifiers.compactMap { identifier -> LanguageOption? in
            let canonical = Locale.identifier(.bcp47, from: identifier)
            let components = Locale.Components(identifier: canonical)
            guard let languageCode = components.languageComponents.languageCode?.identifier,
                  !languageCode.isEmpty,
                  seen.insert(canonical).inserted else {
                return nil
            }
            let languageName = locale.localizedString(forLanguageCode: languageCode)?.capitalized ?? languageCode
            let regionCode = components.region?.identifier
            let regionName = regionCode.flatMap { locale.localizedString(forRegionCode: $0) }
            let label = regionName.map { "\(languageName) — \($0)" } ?? languageName
            let search = [label, canonical, languageCode, regionCode ?? ""].joined(separator: " ").localizedLowercase
            return LanguageOption(identifier: canonical, displayName: label, regionName: regionName, searchableText: search)
        }
        return options.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }
}
