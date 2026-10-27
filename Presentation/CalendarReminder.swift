public import Foundation

/// The optional "meeting starting" reminder (T61, docs/decisions/0006 Goal 5): a local notification about a minute
/// before events in the calendars the user picked. Off by default. It only brings Amaranth forward with the event
/// offered first in the next recording's prompt; it never starts a recording.
public struct CalendarReminder: Hashable, Sendable {
    public static let idPrefix = "amaranth.calendar-reminder."
    public static let lead: TimeInterval = 60
    /// How far ahead reminders are scheduled; the app re-plans every 15 minutes and when calendars change.
    public static let horizon: TimeInterval = 24 * 3600
    /// macOS keeps at most 64 pending notifications per app; stay well under.
    public static let limit = 32

    /// The notification identifier: unique per occurrence.
    public var id: String
    public var eventIdentifier: String
    public var title: String
    public var start: Date
    public var fireDate: Date

    public init(_ e: CalendarEvent) {
        // The title is part of the id, so renaming an event replaces its pending notification on the next sync.
        id = Self.idPrefix + e.id + "#" + String(Self.fnv1a(e.title), radix: 16)
        eventIdentifier = e.identifier
        title = e.title.isEmpty ? "Untitled event" : e.title
        start = e.start
        fireDate = e.start.addingTimeInterval(-Self.lead)
    }

    /// Stable across launches (unlike `hashValue`).
    static func fnv1a(_ s: String) -> UInt64 {
        s.utf8.reduce(14_695_981_039_346_656_037 as UInt64) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }

    /// "Roadmap sync starts in 1 min".
    public var headline: String { "\(title) starts in 1 min" }
    public static let body = "Click to open Amaranth, then press Record. Amaranth never starts recording on its own."

    /// Timed events in `calendars` whose reminder is still ahead (all-day, cancelled and declined skipped), soonest
    /// first, at most `limit`.
    public static func plan(_ events: [CalendarEvent], now: Date, calendars: Set<String>) -> [CalendarReminder] {
        events.filter { e in
            calendars.contains(e.calendarID) && !e.isAllDay && !e.isCancelled && !e.declinedByMe
                && e.start.addingTimeInterval(-lead) > now && e.start <= now.addingTimeInterval(horizon)
        }
        .sorted { $0.start < $1.start }
        .prefix(limit)
        .map(CalendarReminder.init)
    }
}

/// Where reminders go: `UNUserNotificationCenter` in the app, a fake in tests. Only Amaranth's own reminder ids are
/// ever touched.
public protocol ReminderScheduler: AnyObject, Sendable {
    func pendingIDs() async -> Set<String>
    func schedule(_ r: CalendarReminder) async
    func remove(_ ids: Set<String>) async
}

public enum CalendarReminders {
    /// Brings pending reminders in line with the settings. Off, no calendars chosen, or no calendar access: every
    /// pending Amaranth reminder is removed. Otherwise stale ones are removed and missing ones added.
    /// Returns the reminders now scheduled.
    @discardableResult
    public static func sync(enabled: Bool, calendars: Set<String>, source: any CalendarSource, scheduler: any ReminderScheduler,
                            now: Date = Date()) async -> [CalendarReminder] {
        let pending = await scheduler.pendingIDs().filter { $0.hasPrefix(CalendarReminder.idPrefix) }
        guard enabled, !calendars.isEmpty, source.authorization().canRead else {
            if !pending.isEmpty { await scheduler.remove(pending) }
            return []
        }
        let wanted = CalendarReminder.plan(source.events(from: now, to: now.addingTimeInterval(CalendarReminder.horizon + CalendarReminder.lead),
                                                         calendarIDs: calendars), now: now, calendars: calendars)
        let wantedIDs = Set(wanted.map(\.id))
        let stale = pending.subtracting(wantedIDs)
        if !stale.isEmpty { await scheduler.remove(stale) }
        for r in wanted where !pending.contains(r.id) { await scheduler.schedule(r) }
        return wanted
    }
}

/// In-memory scheduler for tests.
public final class FakeReminderScheduler: ReminderScheduler, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String: CalendarReminder] = [:]
    private var others: Set<String>
    public init(otherPending: Set<String> = []) { others = otherPending }
    public var scheduled: [CalendarReminder] { lock.withLock { pending.values.sorted { $0.fireDate < $1.fireDate } } }
    public var foreignIDs: Set<String> { lock.withLock { others } }
    public func pendingIDs() async -> Set<String> { lock.withLock { Set(pending.keys).union(others) } }
    public func schedule(_ r: CalendarReminder) async { lock.withLock { pending[r.id] = r } }
    public func remove(_ ids: Set<String>) async { lock.withLock { for id in ids { pending[id] = nil; others.remove(id) } } }
}
