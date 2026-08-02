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

enum CaptureTiming: String, Codable, CaseIterable, Sendable {
    case alwaysOn
    case schedule

    var displayName: String {
        switch self {
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
        if settings.captureTiming == .schedule, !settings.isCaptureWindowActive(at: Date()) {
            return .schedule
        }
        return switch (settings.screenCaptureEnabled, settings.isListenEnabled) {
        case (true, false): .observe
        case (false, true): .listen
        case (true, true): .observeAndListen
        case (false, false): .paused
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

enum FollowUpSensitivity: String, Codable, CaseIterable, Identifiable, Sendable {
    case essential
    case focused
    case balanced
    case detailed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .essential: "Essential"
        case .focused: "Focused"
        case .balanced: "Balanced"
        case .detailed: "Detailed"
        }
    }

    var explanation: String {
        switch self {
        case .essential: "Only explicit deadlines and high-confidence, important actions."
        case .focused: "Clear commitments and useful actions, with most minor loose ends ignored."
        case .balanced: "Important actions plus credible everyday follow-ups. Recommended for most people."
        case .detailed: "Includes smaller actionable details and lower-confidence possibilities in Maybe."
        }
    }

    var promptGuidance: String {
        switch self {
        case .essential: "Extract only explicit or high-consequence commitments. Ignore minor errands, vague possibilities, and casual intentions."
        case .focused: "Extract clear commitments and useful next actions. Ignore weak implications and low-value details."
        case .balanced: "Extract clear commitments and credible implied next actions when they would be useful to remember."
        case .detailed: "Also extract small but actionable loose ends. Put uncertain or weakly implied items in maybe rather than presenting them as facts."
        }
    }

    var minimumConfidence: Double {
        switch self {
        case .essential: 0.86
        case .focused: 0.76
        case .balanced: 0.64
        case .detailed: 0.48
        }
    }

    var minimumImportance: EventImportance {
        switch self {
        case .essential: .important
        case .focused, .balanced: .normal
        case .detailed: .background
        }
    }

    func accepts(confidence: Double, importance: EventImportance, hasExplicitDueDate: Bool) -> Bool {
        if hasExplicitDueDate { return confidence >= min(minimumConfidence, 0.65) }
        return confidence >= minimumConfidence && importance >= minimumImportance
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
              let minute = components.minute else {
            return false
        }
        let value = hour * 60 + minute
        if startMinutes <= endMinutes {
            return weekdays.contains(weekday) && value >= startMinutes && value < endMinutes
        }
        if value >= startMinutes { return weekdays.contains(weekday) }
        guard value < endMinutes,
              let previousDay = calendar.date(byAdding: .day, value: -1, to: date),
              let previousWeekday = calendar.dateComponents([.weekday], from: previousDay).weekday else {
            return false
        }
        return weekdays.contains(previousWeekday)
    }
}

struct IrizSettings: Codable, Equatable, Sendable {
    var hasCompletedOnboarding = false
    var isPaused = true
    var screenCaptureEnabled = true
    var audioMode: AudioMode = .off
    var captureTiming: CaptureTiming = .alwaysOn
    var audioSchedule = AudioSchedule()
    var meetingDetectionEnabled = true
    var voiceEnrollmentEnabled = false
    var outputLanguageTag = "auto"
    var followUpSensitivity: FollowUpSensitivity = .balanced
    var structuredRetention: StructuredRetention = .forever
    var mediaRetentionHours = 24
    var dailyDigestEnabled = true
    var dailyDigestHour = 9
    var launchAtLogin = false
    var excludedBundleIdentifiers: Set<String> = ExclusionPolicy.defaultExcludedBundleIdentifiers
    var excludedDomains: Set<String> = []

    var isListenEnabled: Bool { audioMode != .off }

    var isScreenCaptureActiveNow: Bool { isScreenCaptureActive(at: Date()) }
    var isAudioActiveNow: Bool { isAudioActive(at: Date()) }

    func isCaptureWindowActive(at date: Date, calendar: Calendar = .current) -> Bool {
        captureTiming == .alwaysOn || audioSchedule.isActive(at: date, calendar: calendar)
    }

    func isScreenCaptureActive(at date: Date, calendar: Calendar = .current) -> Bool {
        !isPaused && screenCaptureEnabled && isCaptureWindowActive(at: date, calendar: calendar)
    }

    func isAudioActive(at date: Date, calendar: Calendar = .current) -> Bool {
        !isPaused && isListenEnabled && isCaptureWindowActive(at: date, calendar: calendar)
    }

    mutating func setObserveEnabled(_ enabled: Bool) {
        screenCaptureEnabled = enabled
        if !enabled, audioMode == .off { isPaused = true }
    }

    mutating func setListenEnabled(_ enabled: Bool) {
        if enabled {
            audioMode = .alwaysOn
        } else {
            audioMode = .off
            if !screenCaptureEnabled { isPaused = true }
        }
    }

    mutating func setListeningBehavior(_ mode: AudioMode) {
        guard mode != .off else { return }
        audioMode = .alwaysOn
        captureTiming = mode == .schedule ? .schedule : .alwaysOn
    }

    mutating func setCaptureTiming(_ timing: CaptureTiming) {
        captureTiming = timing
        if audioMode == .schedule { audioMode = .alwaysOn }
    }

    private enum CodingKeys: String, CodingKey {
        case hasCompletedOnboarding
        case isPaused
        case screenCaptureEnabled
        case audioMode
        case captureTiming
        case audioSchedule
        case meetingDetectionEnabled
        case voiceEnrollmentEnabled
        case outputLanguageTag
        case followUpSensitivity
        case structuredRetention
        case mediaRetentionHours
        case dailyDigestEnabled
        case dailyDigestHour
        case launchAtLogin
        case excludedBundleIdentifiers
        case excludedDomains
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hasCompletedOnboarding = try values.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        isPaused = try values.decodeIfPresent(Bool.self, forKey: .isPaused) ?? true
        screenCaptureEnabled = try values.decodeIfPresent(Bool.self, forKey: .screenCaptureEnabled) ?? true
        let legacyAudioMode = try values.decodeIfPresent(AudioMode.self, forKey: .audioMode) ?? .off
        audioMode = legacyAudioMode == .schedule ? .alwaysOn : legacyAudioMode
        captureTiming = try values.decodeIfPresent(CaptureTiming.self, forKey: .captureTiming)
            ?? (legacyAudioMode == .schedule ? .schedule : .alwaysOn)
        audioSchedule = try values.decodeIfPresent(AudioSchedule.self, forKey: .audioSchedule) ?? AudioSchedule()
        meetingDetectionEnabled = try values.decodeIfPresent(Bool.self, forKey: .meetingDetectionEnabled) ?? true
        voiceEnrollmentEnabled = try values.decodeIfPresent(Bool.self, forKey: .voiceEnrollmentEnabled) ?? false
        outputLanguageTag = try values.decodeIfPresent(String.self, forKey: .outputLanguageTag) ?? "auto"
        followUpSensitivity = try values.decodeIfPresent(FollowUpSensitivity.self, forKey: .followUpSensitivity) ?? .balanced
        structuredRetention = try values.decodeIfPresent(StructuredRetention.self, forKey: .structuredRetention) ?? .forever
        mediaRetentionHours = try values.decodeIfPresent(Int.self, forKey: .mediaRetentionHours) ?? 24
        dailyDigestEnabled = try values.decodeIfPresent(Bool.self, forKey: .dailyDigestEnabled) ?? true
        dailyDigestHour = try values.decodeIfPresent(Int.self, forKey: .dailyDigestHour) ?? 9
        launchAtLogin = try values.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        excludedBundleIdentifiers = try values.decodeIfPresent(Set<String>.self, forKey: .excludedBundleIdentifiers)
            ?? ExclusionPolicy.defaultExcludedBundleIdentifiers
        excludedDomains = try values.decodeIfPresent(Set<String>.self, forKey: .excludedDomains) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(hasCompletedOnboarding, forKey: .hasCompletedOnboarding)
        try values.encode(isPaused, forKey: .isPaused)
        try values.encode(screenCaptureEnabled, forKey: .screenCaptureEnabled)
        try values.encode(audioMode, forKey: .audioMode)
        try values.encode(captureTiming, forKey: .captureTiming)
        try values.encode(audioSchedule, forKey: .audioSchedule)
        try values.encode(meetingDetectionEnabled, forKey: .meetingDetectionEnabled)
        try values.encode(voiceEnrollmentEnabled, forKey: .voiceEnrollmentEnabled)
        try values.encode(outputLanguageTag, forKey: .outputLanguageTag)
        try values.encode(followUpSensitivity, forKey: .followUpSensitivity)
        try values.encode(structuredRetention, forKey: .structuredRetention)
        try values.encode(mediaRetentionHours, forKey: .mediaRetentionHours)
        try values.encode(dailyDigestEnabled, forKey: .dailyDigestEnabled)
        try values.encode(dailyDigestHour, forKey: .dailyDigestHour)
        try values.encode(launchAtLogin, forKey: .launchAtLogin)
        try values.encode(excludedBundleIdentifiers, forKey: .excludedBundleIdentifiers)
        try values.encode(excludedDomains, forKey: .excludedDomains)
    }
}

enum CaptureHealth: Equatable, Sendable {
    case paused
    case observing
    case listening
    case observingAndListening
    case waitingForSchedule
    case meeting
    case processing
    case permissionNeeded(String)
    case error(String)

    var displayName: String {
        switch self {
        case .paused: "Paused"
        case .observing: "Observing"
        case .listening: "Listening"
        case .observingAndListening: "Observing + listening"
        case .waitingForSchedule: "Waiting"
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
