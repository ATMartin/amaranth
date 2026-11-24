import Testing
import Foundation
import Domain
import Storage
@testable import Presentation

@Suite("Suggest the event at Record (T59)")
struct CalendarSuggestionTests {
    static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    static func ev(_ id: String, start minutes: Double, length: Double = 30, allDay: Bool = false, cancelled: Bool = false,
                   declined: Bool = false, recurring: Bool = false) -> CalendarEvent {
        CalendarEvent(identifier: id, title: id, start: now.addingTimeInterval(minutes * 60), end: now.addingTimeInterval((minutes + length) * 60),
                      isAllDay: allDay, isCancelled: cancelled, isRecurring: recurring,
                      attendees: declined ? [CalendarAttendee(name: "Me", response: .declined, isCurrentUser: true)] : [])
    }

    struct Row: CustomTestStringConvertible, Sendable {
        let name: String
        let events: [CalendarEvent]
        let expected: [String]
        var preferred: String? = nil
        var testDescription: String { name }
    }

    static let rows: [Row] = [
        Row(name: "in progress", events: [ev("standup", start: -5)], expected: ["standup"]),
        Row(name: "starts in 9 min", events: [ev("sync", start: 9)], expected: ["sync"]),
        Row(name: "starts in exactly 10 min", events: [ev("sync", start: 10)], expected: ["sync"]),
        Row(name: "starts in 11 min", events: [ev("sync", start: 11)], expected: []),
        Row(name: "ended just now", events: [ev("done", start: -30, length: 30)], expected: []),
        Row(name: "overlapping invitations: running (latest start first), then upcoming", events: [ev("long", start: -50, length: 90), ev("soon", start: 4),
             ev("just-started", start: -2), ev("later", start: 8)], expected: ["just-started", "long", "soon", "later"]),
        Row(name: "all-day ignored", events: [ev("offsite", start: -600, length: 1440, allDay: true), ev("sync", start: 0)], expected: ["sync"]),
        Row(name: "declined ignored", events: [ev("skip", start: -1, declined: true)], expected: []),
        Row(name: "cancelled ignored", events: [ev("gone", start: 2, cancelled: true)], expected: []),
        Row(name: "recurring: only the current occurrence", events: [ev("weekly", start: -10, recurring: true), ev("weekly", start: 7 * 1440 - 10, recurring: true)],
            expected: ["weekly"]),
        Row(name: "a reminder's event comes first", events: [ev("a", start: -3), ev("b", start: 5)], expected: ["b", "a"], preferred: "b"),
        Row(name: "a preferred event that no longer fits is not added", events: [ev("a", start: -3)], expected: ["a"], preferred: "gone"),
    ]

    @Test(arguments: rows) func matching(_ row: Row) {
        #expect(CalendarSuggestion.candidates(row.events, at: Self.now, preferred: row.preferred).map(\.identifier) == row.expected)
    }

    @Test func promptShape() {
        #expect(CalendarSuggestion.Prompt([]) == .none)
        let one = Self.ev("Roadmap sync", start: 0)
        #expect(CalendarSuggestion.Prompt([one]) == .one(one), "one match still asks: it is never linked on its own")
        #expect(CalendarSuggestion.Prompt([one, Self.ev("b", start: 1)]) == .several([one, Self.ev("b", start: 1)]))
        #expect(CalendarSuggestion.question(one) == "Roadmap sync?")
    }

    /// A typed or renamed title is never changed; only the automatic one is replaced, and only on approval.
    @Test func titleOnlyReplacesTheAutomaticOne() {
        let e = Self.ev("Roadmap sync", start: 0)
        let auto = "Meeting — Oct 27, 2026 10:01 AM"
        #expect(CalendarSuggestion.titleAfterApproval(current: auto, automatic: auto, event: e) == "Roadmap sync")
        #expect(CalendarSuggestion.titleAfterApproval(current: "Budget review", automatic: nil, event: e) == nil, "typed at Record")
        #expect(CalendarSuggestion.titleAfterApproval(current: "Renamed meanwhile", automatic: auto, event: e) == nil, "renamed while recording")
        var untitled = e; untitled.title = "  "
        #expect(CalendarSuggestion.titleAfterApproval(current: auto, automatic: auto, event: untitled) == nil)
    }

    @Test func windowCoversLongRunningEventsAndTheLookahead() {
        let w = CalendarSuggestion.window(at: Self.now)
        #expect(w.start <= Self.now.addingTimeInterval(-3 * 3600) && w.end > Self.now.addingTimeInterval(600))
    }

    /// Approval through the store: links and renames an automatic title; the recorder's next state save keeps it; a
    /// typed title is never replaced. Without approval nothing is stored.
    @Test func approvalLinksAndRenamesOnlyAnAutomaticTitle() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "amr-suggest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let auto = RecorderPresentation.automaticTitle(Self.now)
        var recording = Meeting(title: auto, createdAt: Self.now, captureState: .recording)
        try store.upsertMeeting(recording)
        let e = CalendarEvent(identifier: "evt", title: "Roadmap sync", start: Self.now, end: Self.now.addingTimeInterval(1800),
                              attendees: [CalendarAttendee(name: "Dana Whitfield")])
        #expect(try store.meeting(recording.id)?.linkedEvent == nil, "offering a suggestion stores nothing")
        #expect(try CalendarSuggestion.approve(e, for: recording.id, in: store, automaticTitle: auto) == "Roadmap sync")
        recording.captureState = .stopping   // the session's own copy still has the automatic title
        try store.upsertMeeting(recording, keepingStoredTitle: true)
        let stored = try #require(try store.meeting(recording.id))
        #expect(stored.title == "Roadmap sync" && stored.linkedEvent?.identifier == "evt" && stored.people.map(\.name) == ["Dana Whitfield"])
        #expect(stored.captureState == .stopping)
        let typed = Meeting(title: "Budget review", createdAt: Self.now, captureState: .recording)
        try store.upsertMeeting(typed)
        #expect(try CalendarSuggestion.approve(e, for: typed.id, in: store, automaticTitle: nil) == nil)
        #expect(try store.meeting(typed.id)?.title == "Budget review" && store.meeting(typed.id)?.linkedEvent != nil)
    }
}
