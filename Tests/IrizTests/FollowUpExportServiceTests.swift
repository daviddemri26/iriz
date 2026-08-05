@preconcurrency import EventKit
import Foundation
import Testing
@testable import Iriz

@Suite("Follow-up export")
struct FollowUpExportServiceTests {
    @Test("Iriz priority maps to Reminders priority bands")
    func reminderPriorityMapping() {
        #expect(FollowUpExportService.reminderPriority(for: 0) == 0)
        #expect(FollowUpExportService.reminderPriority(for: 1) == 9)
        #expect(FollowUpExportService.reminderPriority(for: 4) == 9)
        #expect(FollowUpExportService.reminderPriority(for: 5) == 5)
        #expect(FollowUpExportService.reminderPriority(for: 7) == 5)
        #expect(FollowUpExportService.reminderPriority(for: 8) == 1)
        #expect(FollowUpExportService.reminderPriority(for: 10) == 1)
        #expect(FollowUpExportService.reminderPriority(for: -1) == 0)
        #expect(FollowUpExportService.reminderPriority(for: 11) == 1)
    }

    @Test("Share text contains structured follow-up details")
    func structuredPlainText() throws {
        let dueDate = try #require(
            Calendar(identifier: .gregorian).date(
                from: DateComponents(timeZone: TimeZone(secondsFromGMT: 0), year: 2026, month: 8, day: 4, hour: 18, minute: 30)
            )
        )
        let payload = FollowUpExportPayload(
            title: "Send the launch brief",
            notes: "Include the final screenshots.",
            priority: 9,
            dueDate: dueDate,
            sourceURL: URL(string: "https://example.com/projects/launch")
        )

        let text = FollowUpExportService.plainText(
            for: payload,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: try #require(TimeZone(secondsFromGMT: 0))
        )

        #expect(text.contains("Title: Send the launch brief"))
        #expect(text.contains("Priority: 9/10"))
        #expect(text.contains("Due: Aug 4, 2026"))
        #expect(text.contains("6:30"))
        #expect(text.contains("Source: https://example.com/projects/launch"))
        #expect(text.hasSuffix("Notes:\nInclude the final screenshots."))
    }

    @Test("Share text omits absent optional fields and clamps priority")
    func minimalPlainText() {
        let text = FollowUpExportService.plainText(
            for: FollowUpExportPayload(title: "Review draft", notes: "  ", priority: -3)
        )

        #expect(text == "Action\nTitle: Review draft\nPriority: 0/10")
    }

    @Test("Reminder due components preserve local calendar values")
    func reminderDueDateComponents() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let date = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 5, hour: 9, minute: 45, second: 12))
        )

        let components = FollowUpExportService.reminderDueDateComponents(for: date, calendar: calendar)

        #expect(components.calendar?.identifier == .gregorian)
        #expect(components.timeZone == calendar.timeZone)
        #expect(components.year == 2026)
        #expect(components.month == 8)
        #expect(components.day == 5)
        #expect(components.hour == 9)
        #expect(components.minute == 45)
        #expect(components.second == 12)
    }

    @Test("Granted Reminders access saves the fully mapped reminder")
    @MainActor
    func grantedRemindersAccess() async throws {
        let store = TestReminderStore(status: .fullAccess)
        let service = FollowUpExportService(reminderStore: store)
        let dueAt = Date(timeIntervalSince1970: 1_785_952_800)
        let sourceURL = try #require(URL(string: "https://example.com/client/acme"))

        let receipt = try await service.addToReminders(
            FollowUpExportPayload(
                title: "  Send Acme proposal  ",
                notes: "  Include pricing  ",
                priority: 9,
                dueDate: dueAt,
                sourceURL: sourceURL
            ),
            calendar: Calendar(identifier: .gregorian)
        )

        #expect(receipt == FollowUpReminderExportReceipt(reminderIdentifier: "reminder-1", calendarTitle: "Reminders"))
        #expect(store.requestCount == 0)
        #expect(store.savedDrafts.count == 1)
        #expect(store.savedDrafts.first?.title == "Send Acme proposal")
        #expect(store.savedDrafts.first?.notes == "Include pricing")
        #expect(store.savedDrafts.first?.priority == 1)
        #expect(store.savedDrafts.first?.dueDateComponents?.year != nil)
        #expect(store.savedDrafts.first?.sourceURL == sourceURL)
    }

    @Test("Denied Reminders access neither requests again nor saves")
    @MainActor
    func deniedRemindersAccess() async {
        let store = TestReminderStore(status: .denied)
        let service = FollowUpExportService(reminderStore: store)

        await #expect(throws: FollowUpExportError.remindersAccessDenied) {
            try await service.addToReminders(FollowUpExportPayload(title: "Review draft"))
        }
        #expect(store.requestCount == 0)
        #expect(store.savedDrafts.isEmpty)
    }

    @Test("A first-use Reminders denial stops before saving")
    @MainActor
    func firstUseRemindersDenial() async {
        let store = TestReminderStore(status: .notDetermined, requestResult: false)
        let service = FollowUpExportService(reminderStore: store)

        await #expect(throws: FollowUpExportError.remindersAccessDenied) {
            try await service.addToReminders(FollowUpExportPayload(title: "Review draft"))
        }
        #expect(store.requestCount == 1)
        #expect(store.savedDrafts.isEmpty)
    }
}

@MainActor
private final class TestReminderStore: FollowUpReminderStore {
    var authorizationStatus: EKAuthorizationStatus
    var requestResult: Bool
    var requestCount = 0
    var savedDrafts: [FollowUpReminderDraft] = []

    init(status: EKAuthorizationStatus, requestResult: Bool = true) {
        authorizationStatus = status
        self.requestResult = requestResult
    }

    func requestFullAccess() async throws -> Bool {
        requestCount += 1
        return requestResult
    }

    func save(_ draft: FollowUpReminderDraft) throws -> FollowUpReminderExportReceipt {
        savedDrafts.append(draft)
        return FollowUpReminderExportReceipt(reminderIdentifier: "reminder-1", calendarTitle: "Reminders")
    }
}
