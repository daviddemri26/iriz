import Foundation
import UserNotifications

actor NotificationService {
    private let center = UNUserNotificationCenter.current()

    func configureDailyDigest(hour: Int, enabled: Bool) async {
        center.removePendingNotificationRequests(withIdentifiers: ["iriz.daily-digest"])
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Your iriz daily review"
        content.body = "A few moments may be worth revisiting. Open Actions when you are ready."
        content.sound = nil
        var components = DateComponents()
        components.hour = min(max(hour, 0), 23)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: "iriz.daily-digest", content: content, trigger: trigger)
        try? await center.add(request)
    }
}
