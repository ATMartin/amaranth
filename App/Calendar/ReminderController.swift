import AppKit
import EventKit
import Foundation
import Observation
import UserNotifications
import Presentation

/// Local notifications through `UNUserNotificationCenter`. Only Amaranth's reminder ids are touched.
final class NotificationReminderScheduler: ReminderScheduler, @unchecked Sendable {
    private var center: UNUserNotificationCenter { .current() }

    func pendingIDs() async -> Set<String> { Set(await center.pendingNotificationRequests().map(\.identifier)) }

    func schedule(_ r: CalendarReminder) async {
        let content = UNMutableNotificationContent()
        content.title = r.headline
        content.body = CalendarReminder.body
        content.sound = .default
        content.userInfo = ["eventIdentifier": r.eventIdentifier]
        // A calendar trigger fires at the wall-clock time even after the Mac slept.
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: r.fireDate)
        try? await center.add(UNNotificationRequest(identifier: r.id, content: content,
                                                    trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
    }

    func remove(_ ids: Set<String>) async { center.removePendingNotificationRequests(withIdentifiers: Array(ids)) }
}

/// The "meeting starting" reminder (T61): keeps pending notifications in line with Settings → Calendar (at launch, every
/// 15 minutes, when calendars change, and when a setting changes). Clicking one brings Amaranth forward and offers that
/// event first in the next recording's prompt. It never starts a recording, and nothing here asks for a permission
/// except `enable()`, which runs when the user turns the reminder on.
@MainActor @Observable
final class ReminderController: NSObject, UNUserNotificationCenterDelegate {
    let calendar: CalendarModel
    weak var recorder: RecorderModel?
    /// Brings the main window forward (set by the app from SwiftUI's openWindow).
    @ObservationIgnored var openMainWindow: (() -> Void)?
    private(set) var notificationsDenied = false
    private(set) var scheduledCount = 0
    @ObservationIgnored private let scheduler: any ReminderScheduler
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    init(calendar: CalendarModel, scheduler: any ReminderScheduler = NotificationReminderScheduler()) {
        self.calendar = calendar
        self.scheduler = scheduler
        super.init()
    }

    /// App launch: become the notification delegate (so a click that launches the app is delivered) and re-plan.
    func start() {
        UNUserNotificationCenter.current().delegate = self
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        sync()
    }

    /// Re-plans from the current settings; turning the reminder off removes every pending one.
    func sync() {
        let enabled = CalendarSettings.reminder(), calendars = CalendarSettings.reminderCalendars()
        let source = calendar.source, scheduler = self.scheduler
        Task {
            let planned = await CalendarReminders.sync(enabled: enabled, calendars: calendars, source: source, scheduler: scheduler)
            scheduledCount = planned.count
        }
    }

    /// The user turned the reminder on: calendar access (if undecided, not while recording), notification permission,
    /// every calendar chosen if none was, then plan.
    func enable() async {
        await calendar.request(.userAction(recording: recorder?.inSession ?? false))
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        notificationsDenied = !granted
        if CalendarSettings.reminderCalendars().isEmpty {
            UserDefaults.standard.set(calendar.source.calendars().map(\.id), forKey: CalendarSettings.reminderCalendarsKey)
        }
        sync()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound] }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.identifier.hasPrefix(CalendarReminder.idPrefix) else { return }
        let id = response.notification.request.content.userInfo["eventIdentifier"] as? String
        await MainActor.run {
            // Offered first when the user presses Record; never starts recording.
            if let id { recorder?.preferredEventID = id }
            openMainWindow?()
            NSApp.activate()
        }
    }
}
