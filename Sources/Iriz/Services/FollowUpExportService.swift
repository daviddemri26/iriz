@preconcurrency import EventKit
import Foundation

struct FollowUpExportPayload: Equatable, Sendable {
    var title: String
    var notes: String?
    var priority: Int
    var dueDate: Date?
    var sourceURL: URL?

    init(
        title: String,
        notes: String? = nil,
        priority: Int = 0,
        dueDate: Date? = nil,
        sourceURL: URL? = nil
    ) {
        self.title = title
        self.notes = notes
        self.priority = priority
        self.dueDate = dueDate
        self.sourceURL = sourceURL
    }
}

struct FollowUpReminderExportReceipt: Equatable, Sendable {
    var reminderIdentifier: String
    var calendarTitle: String
}

struct FollowUpReminderDraft: Equatable, Sendable {
    var title: String
    var notes: String?
    var priority: Int
    var dueDateComponents: DateComponents?
    var sourceURL: URL?
}

@MainActor
protocol FollowUpReminderStore: AnyObject {
    var authorizationStatus: EKAuthorizationStatus { get }
    func requestFullAccess() async throws -> Bool
    func save(_ draft: FollowUpReminderDraft) throws -> FollowUpReminderExportReceipt
}

@MainActor
final class EventKitFollowUpReminderStore: FollowUpReminderStore {
    private let eventStore: EKEventStore

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }

    var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .reminder)
    }

    func requestFullAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            eventStore.requestFullAccessToReminders { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    func save(_ draft: FollowUpReminderDraft) throws -> FollowUpReminderExportReceipt {
        guard let remindersList = eventStore.defaultCalendarForNewReminders() else {
            throw FollowUpExportError.noDefaultRemindersList
        }
        let reminder = EKReminder(eventStore: eventStore)
        reminder.calendar = remindersList
        reminder.title = draft.title
        reminder.notes = draft.notes
        reminder.priority = draft.priority
        reminder.url = draft.sourceURL
        reminder.dueDateComponents = draft.dueDateComponents
        try eventStore.save(reminder, commit: true)
        return FollowUpReminderExportReceipt(
            reminderIdentifier: reminder.calendarItemIdentifier,
            calendarTitle: remindersList.title
        )
    }
}

enum FollowUpExportError: LocalizedError, Equatable, Sendable {
    case emptyTitle
    case remindersAccessDenied
    case remindersAccessRestricted
    case remindersAccessUnavailable
    case noDefaultRemindersList

    var errorDescription: String? {
        switch self {
        case .emptyTitle:
            "Add a title before exporting this follow-up."
        case .remindersAccessDenied:
            "Iriz does not have access to Reminders. You can allow access in System Settings."
        case .remindersAccessRestricted:
            "Access to Reminders is restricted on this Mac."
        case .remindersAccessUnavailable:
            "Reminders access is currently unavailable."
        case .noDefaultRemindersList:
            "Reminders does not have a default list available for new reminders."
        }
    }
}

@MainActor
final class FollowUpExportService {
    private let reminderStore: any FollowUpReminderStore

    init(eventStore: EKEventStore = EKEventStore()) {
        reminderStore = EventKitFollowUpReminderStore(eventStore: eventStore)
    }

    init(reminderStore: any FollowUpReminderStore) {
        self.reminderStore = reminderStore
    }

    @discardableResult
    func addToReminders(
        _ payload: FollowUpExportPayload,
        calendar: Calendar = .autoupdatingCurrent
    ) async throws -> FollowUpReminderExportReceipt {
        let title = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw FollowUpExportError.emptyTitle }

        try await requestFullRemindersAccessIfNeeded()
        return try reminderStore.save(FollowUpReminderDraft(
            title: title,
            notes: payload.notes?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            priority: Self.reminderPriority(for: payload.priority),
            dueDateComponents: payload.dueDate.map { Self.reminderDueDateComponents(for: $0, calendar: calendar) },
            sourceURL: payload.sourceURL
        ))
    }

    nonisolated static func reminderPriority(for irizPriority: Int) -> Int {
        switch min(max(irizPriority, 0), 10) {
        case 8...10: 1
        case 5...7: 5
        case 1...4: 9
        default: 0
        }
    }

    nonisolated static func plainText(
        for payload: FollowUpExportPayload,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        let title = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = [
            "Follow Up",
            "Title: \(title)",
            "Priority: \(min(max(payload.priority, 0), 10))/10"
        ]

        if let dueDate = payload.dueDate {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            lines.append("Due: \(formatter.string(from: dueDate))")
        }
        if let sourceURL = payload.sourceURL {
            lines.append("Source: \(sourceURL.absoluteString)")
        }
        if let notes = payload.notes?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            lines += ["", "Notes:", notes]
        }
        return lines.joined(separator: "\n")
    }

    nonisolated static func reminderDueDateComponents(for date: Date, calendar: Calendar) -> DateComponents {
        calendar.dateComponents(
            [.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second],
            from: date
        )
    }

    private func requestFullRemindersAccessIfNeeded() async throws {
        switch reminderStore.authorizationStatus {
        case .fullAccess:
            return
        case .notDetermined, .writeOnly:
            let granted = try await reminderStore.requestFullAccess()
            guard granted else { throw FollowUpExportError.remindersAccessDenied }
        case .denied:
            throw FollowUpExportError.remindersAccessDenied
        case .restricted:
            throw FollowUpExportError.remindersAccessRestricted
        @unknown default:
            throw FollowUpExportError.remindersAccessUnavailable
        }
    }

}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
