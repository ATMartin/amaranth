public import Foundation
public import Domain
public import Storage

/// Linking a recording to a calendar event from the header chip (T57, docs/decisions/0006 "Data mapping"). The link is
/// a snapshot: nothing refreshes it unless the user presses Update.
public enum CalendarLinking {
    /// The stored snapshot of an event occurrence.
    public static func snapshot(_ e: CalendarEvent) -> LinkedEvent {
        let unnamed = MeetingPeople.unnamedCount(e.attendees)
        return LinkedEvent(identifier: e.identifier, title: e.title, start: e.start, end: e.end, calendarName: e.calendarName, source: .eventKit,
                           unnamedAttendees: unnamed > 0 ? unnamed : nil)
    }

    /// Links `event` to the meeting and merges its attendees (T58), in one store write. The one path every link takes:
    /// the header chip, Update, and an approved suggestion at Record (T59).
    public static func link(_ event: CalendarEvent, to id: MeetingID, in store: MeetingStore, keepEmails: Bool = CalendarSettings.keepEmails()) throws {
        try store.linkEvent(snapshot(event), for: id) { MeetingPeople.merging(event.attendees, into: $0, keepEmails: keepEmails) }
    }

    /// Settings → Calendar → "Remove calendar data from all meetings" (T61): every link and every calendar-sourced
    /// person goes; typed people stay. Returns how many meetings changed.
    @discardableResult
    public static func removeAllCalendarData(in store: MeetingStore) throws -> Int {
        var changed = 0
        for m in try store.meetings() where m.linkedEvent != nil || m.people.contains(where: { $0.source == .calendar || $0.email != nil }) {
            try store.setLinkedEvent(nil, for: m.id)
            try store.setPeople(m.people.filter { $0.source == .manual }.map { Person(name: $0.name, source: .manual) }, for: m.id)
            changed += 1
        }
        if changed > 0 { try store.checkpointAndTruncateWAL() }   // the removed text doesn't linger in the WAL
        return changed
    }

    /// Turning "Keep attendee email addresses" off forgets the addresses already kept (T61). Returns meetings changed.
    @discardableResult
    public static func forgetEmails(in store: MeetingStore) throws -> Int {
        var changed = 0
        for m in try store.meetings() where m.people.contains(where: { $0.email != nil }) {
            try store.setPeople(m.people.map { Person(name: $0.name, source: $0.source) }, for: m.id)
            changed += 1
        }
        if changed > 0 { try store.checkpointAndTruncateWAL() }
        return changed
    }

    /// Title, times and calendar match (attendee changes don't count as "changed").
    static func sameDetails(_ a: LinkedEvent, _ b: LinkedEvent) -> Bool {
        a.identifier == b.identifier && a.title == b.title && a.start == b.start && a.end == b.end && a.calendarName == b.calendarName
    }

    /// The window the picker reads: the recording's local day.
    public static func day(of date: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        let start = calendar.startOfDay(for: date)
        return (start, calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400))
    }

    /// Picker order: timed events nearest the recording's start first, then all-day events. Cancelled events are left
    /// out; declined ones stay (the user may have joined anyway).
    public static func pickerEvents(_ events: [CalendarEvent], recordedAt: Date) -> [CalendarEvent] {
        let live = events.filter { !$0.isCancelled }
        let timed = live.filter { !$0.isAllDay }.sorted {
            let a = distance($0, recordedAt), b = distance($1, recordedAt)
            return a == b ? $0.start < $1.start : a < b
        }
        return timed + live.filter(\.isAllDay).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Zero while the recording started inside the event, else the gap to its nearer edge.
    static func distance(_ e: CalendarEvent, _ t: Date) -> TimeInterval {
        if e.start <= t && t < e.end { return 0 }
        return min(abs(e.start.timeIntervalSince(t)), abs(e.end.timeIntervalSince(t)))
    }

    /// The picker's search field: title, calendar or an attendee's name, ignoring case and accents.
    public static func filter(_ events: [CalendarEvent], query: String) -> [CalendarEvent] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return events }
        func has(_ s: String?) -> Bool { s?.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        return events.filter { e in has(e.title) || has(e.calendarName) || e.attendees.contains { has($0.name) } }
    }

    /// How the stored snapshot compares with the calendar now.
    public enum LiveStatus: Sendable, Equatable {
        /// Same title, times and calendar.
        case current
        /// The event is still there but differs; Update copies these values.
        case changed(CalendarEvent)
        /// Not found around its date: deleted, or the calendar was removed. The snapshot stays.
        case missing
        /// Can't tell without calendar access.
        case unknown
    }

    /// Finds the linked occurrence among `events` (read around the snapshot's start): same identifier and start, else
    /// the same identifier's nearest occurrence on that day (a moved meeting).
    public static func liveStatus(of linked: LinkedEvent, in events: [CalendarEvent], access: CalendarAuthorization) -> LiveStatus {
        guard access.canRead else { return .unknown }
        let same = events.filter { $0.identifier == linked.identifier && !$0.isCancelled }
        guard let match = same.first(where: { $0.start == linked.start })
                ?? same.min(by: { abs($0.start.timeIntervalSince(linked.start)) < abs($1.start.timeIntervalSince(linked.start)) })
                    .flatMap({ abs($0.start.timeIntervalSince(linked.start)) < 86_400 ? $0 : nil }) else { return .missing }
        return sameDetails(snapshot(match), linked) ? .current : .changed(match)
    }

    /// The window to read when checking a snapshot: its start's day, a day either side (moved meetings).
    public static func lookupWindow(_ linked: LinkedEvent) -> (start: Date, end: Date) {
        (linked.start.addingTimeInterval(-86_400), linked.end.addingTimeInterval(86_400))
    }

    /// Other meetings linked to the same occurrence ("Also linked to …"). Several recordings of one event are allowed.
    public static func alsoLinked(_ meeting: Meeting, among linked: [Meeting]) -> [Meeting] {
        guard let event = meeting.linkedEvent else { return [] }
        return linked.filter { $0.id != meeting.id && $0.linkedEvent?.identifier == event.identifier && $0.linkedEvent?.start == event.start }
    }

    /// "Roadmap sync · 10:00–10:30" (times in the user's style); all-day spans read "all day".
    public static func chipLabel(_ e: LinkedEvent, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        "\(e.title.isEmpty ? "Untitled event" : e.title) · \(timeRange(start: e.start, end: e.end, timeZone: timeZone, locale: locale))"
    }

    public static func timeRange(start: Date, end: Date, allDay: Bool = false, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        if allDay { return "all day" }
        var f = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale); f.timeZone = timeZone
        return "\(start.formatted(f))–\(end.formatted(f))"
    }

    /// Tooltip of the linked chip: event, date, calendar, then the state line.
    public static func tooltip(_ e: LinkedEvent, status: LiveStatus, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        var d = Date.FormatStyle(date: .complete, time: .omitted, locale: locale); d.timeZone = timeZone
        var lines = ["Linked to “\(e.title)”, \(e.start.formatted(d)) \(timeRange(start: e.start, end: e.end, timeZone: timeZone, locale: locale))"]
        if let c = e.calendarName { lines.append("Calendar: \(c)") }
        switch status {
        case .changed: lines.append("Event changed since linking")
        case .missing: lines.append("No longer in your calendar")
        case .current, .unknown: break
        }
        return lines.joined(separator: "\n")
    }

    /// "Use event title" is offered when the linked event's title differs from the meeting's (never applied silently).
    public static func offersEventTitle(_ meeting: Meeting) -> Bool {
        guard let t = meeting.linkedEvent?.title.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return false }
        return t != meeting.title
    }
}

/// What the header's calendar chip shows (T57). A stored link always shows, even without access (the snapshot is ours).
public enum CalendarChip: Sendable, Equatable {
    /// "Link calendar event…": asks for access on click if needed, then the picker.
    case link(asks: Bool)
    /// "Calendar access is off": popover with Open Privacy Settings.
    case accessOff
    /// Disabled: the administrator controls calendar access.
    case managed
    case linked(LinkedEvent, CalendarLinking.LiveStatus)

    public static func state(linked: LinkedEvent?, access: CalendarAuthorization, live: CalendarLinking.LiveStatus) -> CalendarChip {
        if let linked { return .linked(linked, access.canRead ? live : .unknown) }
        return switch access.presentation {
        case .askOnClick: .link(asks: true)
        case .ready: .link(asks: false)
        case .off: .accessOff
        case .managed: .managed
        }
    }

    public func label(compact: Bool) -> String {
        switch self {
        case .link(let asks): compact ? "" : asks ? "Link calendar event…" : "Link calendar event"
        case .accessOff: compact ? "" : "Calendar access is off"
        case .managed: compact ? "" : "Link calendar event"
        case .linked(let e, _): compact ? (e.title.isEmpty ? "Untitled event" : e.title) : CalendarLinking.chipLabel(e)
        }
    }

    public var symbol: String {
        switch self {
        case .link, .managed: "link"
        case .accessOff: "calendar.badge.exclamationmark"
        case .linked(_, .changed): "arrow.triangle.2.circlepath"
        case .linked(_, .missing): "calendar.badge.exclamationmark"
        case .linked: "calendar.badge.checkmark"
        }
    }

    public var help: String {
        switch self {
        case .link(true): "Link this recording to a calendar event. Amaranth asks for calendar access first; nothing leaves this Mac."
        case .link(false): "Link this recording to an event from your calendar"
        case .accessOff: "Calendar access is off for Amaranth. Click to see how to turn it on."
        case .managed: "Your administrator controls calendar access on this Mac"
        case .linked(let e, let status): CalendarLinking.tooltip(e, status: status)
        }
    }

    /// Changed or missing events draw in the attention colour.
    public var needsAttention: Bool {
        switch self {
        case .linked(_, .changed), .linked(_, .missing): true
        default: false
        }
    }
}
