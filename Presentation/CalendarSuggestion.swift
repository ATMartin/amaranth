public import Foundation
public import Domain
public import Storage

/// The event offered when recording starts (T59, docs/decisions/0006 Goal 2). It is only ever a question: nothing is
/// linked or renamed until the user picks Link (or an event under "Which meeting?").
public enum CalendarSuggestion {
    /// An event starting within this many seconds counts as "now".
    public static let lookahead: TimeInterval = 10 * 60

    /// The window to read from the calendar at `now`.
    public static func window(at now: Date) -> (start: Date, end: Date) {
        (now.addingTimeInterval(-24 * 3600), now.addingTimeInterval(lookahead + 1))
    }

    /// Events in progress at `now` or starting within 10 minutes (inclusive). All-day, cancelled and declined events
    /// are ignored. Order: `preferred` first (the event a reminder was clicked for, T61), then events in progress (the
    /// most recently started first), then upcoming ones (soonest first).
    public static func candidates(_ events: [CalendarEvent], at now: Date, preferred: String? = nil) -> [CalendarEvent] {
        var seen = Set<String>()
        let fitting = events.filter { e in
            !e.isAllDay && !e.isCancelled && !e.declinedByMe && e.end > now
                && (e.start <= now || e.start.timeIntervalSince(now) <= lookahead) && seen.insert(e.id).inserted
        }
        let running = fitting.filter { $0.start <= now }.sorted { $0.start > $1.start }
        let upcoming = fitting.filter { $0.start > now }.sorted { $0.start < $1.start }
        let ordered = running + upcoming
        guard let preferred, let i = ordered.firstIndex(where: { $0.identifier == preferred }) else { return ordered }
        return [ordered[i]] + ordered.enumerated().filter { $0.offset != i }.map(\.element)
    }

    /// The prompt in the recording strip: one match asks "<title>?" (Link / Not this), several ask "Which meeting?".
    public enum Prompt: Sendable, Equatable {
        case none
        case one(CalendarEvent)
        case several([CalendarEvent])

        public init(_ candidates: [CalendarEvent]) {
            switch candidates.count {
            case 0: self = .none
            case 1: self = .one(candidates[0])
            default: self = .several(candidates)
            }
        }
    }

    /// "Roadmap sync?" (an untitled event reads "Untitled event?").
    public static func question(_ e: CalendarEvent) -> String { "\(e.title.isEmpty ? "Untitled event" : e.title)?" }

    /// The title after the user approves `event`: the event's title only if the meeting still has the automatic title
    /// it got at Record (nothing typed, nothing renamed since); otherwise nil (keep the title).
    public static func titleAfterApproval(current: String, automatic: String?, event: CalendarEvent) -> String? {
        let t = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let automatic, current == automatic, !t.isEmpty else { return nil }
        return t
    }

    /// What approving does (the strip's Link, or a choice under "Which meeting?"): link and merge attendees through the
    /// one link path, then take the event's title only under `titleAfterApproval`'s rule. Returns the new title, if any.
    @discardableResult
    public static func approve(_ event: CalendarEvent, for id: MeetingID, in store: MeetingStore, automaticTitle: String?,
                               keepEmails: Bool = CalendarSettings.keepEmails()) throws -> String? {
        try CalendarLinking.link(event, to: id, in: store, keepEmails: keepEmails)
        guard var m = try store.meeting(id), let t = titleAfterApproval(current: m.title, automatic: automaticTitle, event: event) else { return nil }
        m.title = t
        try store.upsertMeeting(m)
        return t
    }
}
