import Foundation
import UserNotifications
import Presentation

/// The "Still recording?" notification (T68). Posting never asks for permission: without it, the amber strip and the
/// menu bar icon still show the alert. The one ask is right after a recording ends (`askAfterStopIfNeeded`), once.
enum QuietNotifications {
    static let category = "amaranth.quiet"
    static let stopAction = "amaranth.quiet.stop"
    static let keepAction = "amaranth.quiet.keep"
    static let idPrefix = "amaranth.quiet."

    /// At launch (with the notification delegate): the two buttons.
    static func registerCategory() {
        let stop = UNNotificationAction(identifier: stopAction, title: "Stop & Make Notes", options: [])
        let keep = UNNotificationAction(identifier: keepAction, title: "Keep Recording", options: [])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: category, actions: [stop, keep], intentIdentifiers: [], options: [])])
    }

    static func id(_ meeting: String) -> String { idPrefix + meeting }

    static func post(title: String, body: String, meeting: String) {
        let center = UNUserNotificationCenter.current()
        Task {
            let settings = await center.notificationSettings()
            guard [.authorized, .provisional].contains(settings.authorizationStatus) else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.categoryIdentifier = category
            try? await center.add(UNNotificationRequest(identifier: id(meeting), content: content, trigger: nil))
        }
    }

    /// Speech resumed, Keep Recording, or Stop: the notification no longer applies.
    static func remove(meeting: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id(meeting)])
    }

    /// After a Stop (never during a recording or at launch): whether to ask now — the alert is on, Amaranth hasn't asked
    /// before, and nothing was decided (an earlier "Allow" for the T61 reminder counts as decided).
    static func shouldAskAfterStop(_ defaults: UserDefaults = .standard) async -> Bool {
        guard QuietAlertSettings.enabled(defaults), !defaults.bool(forKey: QuietAlertSettings.askedKey) else { return false }
        guard await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .notDetermined else {
            defaults.set(true, forKey: QuietAlertSettings.askedKey); return false
        }
        return true
    }

    /// Settings → turning the alert on (outside a recording): ask if undecided.
    static func ask(_ defaults: UserDefaults = .standard) async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else {
            defaults.set(true, forKey: QuietAlertSettings.askedKey); return
        }
        defaults.set(true, forKey: QuietAlertSettings.askedKey)
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }
}
