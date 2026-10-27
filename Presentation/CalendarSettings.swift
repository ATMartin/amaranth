public import Foundation

/// Settings → Calendar (T58, T59, T61; docs/decisions/0006). UserDefaults keys and defaults in one place.
public enum CalendarSettings {
    /// "Suggest calendar events when recording" (T59). On by default; it only acts once access was granted.
    public static let suggestKey = "calendarSuggestEvents"
    public static let suggestDefault = true
    /// "Remind me when a meeting is about to start" (T61). Off by default.
    public static let reminderKey = "calendarReminder"
    public static let reminderDefault = false
    /// Calendar identifiers the reminder watches (T61); empty means none chosen yet.
    public static let reminderCalendarsKey = "calendarReminderCalendars"
    /// "Keep attendee email addresses" (T58). Off by default: only names are stored.
    public static let keepEmailsKey = "calendarKeepAttendeeEmails"
    public static let keepEmailsDefault = false

    public static func suggest(_ d: UserDefaults = .standard) -> Bool { d.object(forKey: suggestKey) as? Bool ?? suggestDefault }
    public static func reminder(_ d: UserDefaults = .standard) -> Bool { d.object(forKey: reminderKey) as? Bool ?? reminderDefault }
    public static func keepEmails(_ d: UserDefaults = .standard) -> Bool { d.object(forKey: keepEmailsKey) as? Bool ?? keepEmailsDefault }
    public static func reminderCalendars(_ d: UserDefaults = .standard) -> Set<String> { Set(d.stringArray(forKey: reminderCalendarsKey) ?? []) }
}
