import Foundation
public import Domain

/// The header's people chip and its names editor (T50), and attendees of a linked event (T58).
public enum MeetingPeople {
    /// Names typed one per line or separated by commas, trimmed and de-duplicated ignoring case. A name already on the
    /// meeting keeps its source (and kept email), so editing never turns calendar people into manual ones.
    public static func parse(_ text: String, keeping existing: [Person] = []) -> [Person] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "\n" || $0 == "," }).compactMap { part -> Person? in
            let name = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { return nil }
            let kept = existing.first { $0.name.lowercased() == name.lowercased() }
            return Person(name: name, source: kept?.source ?? .manual, email: kept?.email)
        }
    }

    /// The editor's starting text: one name per line.
    public static func editableText(_ people: [Person]) -> String { people.map(\.name).joined(separator: "\n") }

    /// Chip label: "Add people…" when empty, up to two names, then "+N"; a linked event's unnamed invitees add
    /// " · 2 unnamed" (T58).
    public static func chipLabel(_ people: [Person], unnamed: Int = 0) -> String {
        let more = unnamed > 0 ? "\(unnamed) unnamed" : nil
        guard !people.isEmpty else { return more.map { "+" + $0 } ?? "Add people…" }
        let shown = people.prefix(2).map(\.name).joined(separator: ", ")
        let names = people.count > 2 ? "\(shown) +\(people.count - 2)" : shown
        return more.map { "\(names) · \($0)" } ?? names
    }

    /// Attendees that become people (T58): people (and unknown kinds) with a display name; rooms, resources and groups
    /// are never people. The current user comes first.
    public static func namedAttendees(_ attendees: [CalendarAttendee]) -> [CalendarAttendee] {
        let named = attendees.filter { a in a.kind != .room && a.kind != .resource && a.kind != .group && a.name != nil }
        return named.filter(\.isCurrentUser) + named.filter { !$0.isCurrentUser }
    }

    /// Invited people without a display name: skipped, never stored, and not replaced by the email's local part.
    public static func unnamedCount(_ attendees: [CalendarAttendee]) -> Int {
        attendees.filter { a in a.kind != .room && a.kind != .resource && a.kind != .group && a.name == nil }.count
    }

    /// Linking merges attendees into the meeting's people (T58): everyone already listed stays exactly as they are
    /// (manual people are never renamed, re-sourced or removed); attendees not yet listed (ignoring case) are added
    /// after them as `.calendar`, current user first. Emails are kept only when `keepEmails` is on.
    public static func merging(_ attendees: [CalendarAttendee], into people: [Person], keepEmails: Bool) -> [Person] {
        var seen = Set(people.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        var out = people
        for a in namedAttendees(attendees) {
            guard let name = a.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
            out.append(Person(name: name, source: .calendar, email: keepEmails ? a.email : nil))
        }
        return out
    }

    /// Tooltip and VoiceOver text: every name, and how many invitees had no name.
    public static func fullList(_ people: [Person], unnamed: Int = 0) -> String {
        let list = people.isEmpty ? "No people added" : "People: " + people.map(\.name).joined(separator: ", ")
        return unnamed > 0 ? list + " (\(unnamed) invited without a name)" : list
    }

    /// Names that came from a calendar event, for the editor's calendar line.
    public static func calendarNames(_ people: [Person]) -> [String] { people.filter { $0.source == .calendar }.map(\.name) }
}
