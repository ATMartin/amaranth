import Testing
import Foundation
import Domain
import Storage
@testable import Presentation

@Suite("Attendees become people (T58)")
struct CalendarPeopleTests {
    static let me = CalendarAttendee(name: "Alex Martin", email: "alex@example.com", isCurrentUser: true)
    static let dana = CalendarAttendee(name: "Dana Whitfield", email: "dana@example.com")
    static let ravi = CalendarAttendee(name: "Ravi Patel", email: "ravi@example.com")
    static let room = CalendarAttendee(name: "Room 4B", kind: .room)
    static let projector = CalendarAttendee(name: "Projector", kind: .resource)
    static let list = CalendarAttendee(name: "eng-all", kind: .group)
    static let unnamed = CalendarAttendee(name: nil, email: "guest@example.com")
    static let blank = CalendarAttendee(name: nil, email: nil, kind: .unknown)

    struct Row: CustomTestStringConvertible, Sendable {
        let name: String
        let existing: [Person]
        let attendees: [CalendarAttendee]
        let keepEmails: Bool
        let expected: [Person]
        var testDescription: String { name }
    }

    static let rows: [Row] = [
        Row(name: "empty meeting: named people only, current user first", existing: [], attendees: [dana, room, unnamed, me, projector, list, ravi, blank],
            keepEmails: false, expected: [Person(name: "Alex Martin", source: .calendar), Person(name: "Dana Whitfield", source: .calendar),
                                          Person(name: "Ravi Patel", source: .calendar)]),
        Row(name: "manual people stay first and unchanged; a manual name is not duplicated or re-sourced",
            existing: [Person(name: "dana whitfield"), Person(name: "Zoe")], attendees: [me, dana, ravi], keepEmails: false,
            expected: [Person(name: "dana whitfield"), Person(name: "Zoe"), Person(name: "Alex Martin", source: .calendar),
                       Person(name: "Ravi Patel", source: .calendar)]),
        Row(name: "re-linking the same event adds nothing", existing: [Person(name: "Alex Martin", source: .calendar), Person(name: "Dana Whitfield", source: .calendar)],
            attendees: [me, dana], keepEmails: false,
            expected: [Person(name: "Alex Martin", source: .calendar), Person(name: "Dana Whitfield", source: .calendar)]),
        Row(name: "linking another event merges only the new names", existing: [Person(name: "Dana Whitfield", source: .calendar), Person(name: "Zoe")],
            attendees: [dana, ravi], keepEmails: false,
            expected: [Person(name: "Dana Whitfield", source: .calendar), Person(name: "Zoe"), Person(name: "Ravi Patel", source: .calendar)]),
        Row(name: "emails only with the setting on", existing: [], attendees: [dana, unnamed], keepEmails: true,
            expected: [Person(name: "Dana Whitfield", source: .calendar, email: "dana@example.com")]),
        Row(name: "no attendees: people unchanged", existing: [Person(name: "Zoe")], attendees: [], keepEmails: true, expected: [Person(name: "Zoe")]),
    ]

    @Test(arguments: rows) func mergeRules(_ row: Row) {
        #expect(MeetingPeople.merging(row.attendees, into: row.existing, keepEmails: row.keepEmails) == row.expected)
    }

    @Test func unnamedAreCountedNotStored() {
        #expect(MeetingPeople.unnamedCount([Self.dana, Self.unnamed, Self.blank, Self.room]) == 2)
        #expect(MeetingPeople.chipLabel([Person(name: "Ana"), Person(name: "Ben"), Person(name: "Cy")], unnamed: 2) == "Ana, Ben +1 · 2 unnamed")
        #expect(MeetingPeople.chipLabel([], unnamed: 2) == "+2 unnamed")
        #expect(MeetingPeople.chipLabel([], unnamed: 0) == "Add people…")
        #expect(MeetingPeople.fullList([Person(name: "Ana")], unnamed: 1) == "People: Ana (1 invited without a name)")
    }

    @Test func editingKeepsCalendarSourceAndEmail() {
        let existing = [Person(name: "Dana Whitfield", source: .calendar, email: "dana@example.com")]
        #expect(MeetingPeople.parse("Dana Whitfield\nZoe", keeping: existing)
                == [Person(name: "Dana Whitfield", source: .calendar, email: "dana@example.com"), Person(name: "Zoe")])
    }

    /// Link, unlink (people stay), re-link (no duplicates), link another event (merged), manual never touched.
    @Test func linkUnlinkRelinkThroughTheStore() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "amr-cal-people-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let m = Meeting(title: "Sync", createdAt: Date())
        try store.upsertMeeting(m)
        try store.setPeople([Person(name: "Zoe")], for: m.id)
        let t = Date()
        let a = CalendarEvent(identifier: "a", title: "Roadmap sync", start: t, end: t.addingTimeInterval(1800), attendees: [Self.me, Self.dana, Self.unnamed, Self.room])
        let b = CalendarEvent(identifier: "b", title: "Follow-up", start: t, end: t.addingTimeInterval(1800), attendees: [Self.dana, Self.ravi])
        try CalendarLinking.link(a, to: m.id, in: store, keepEmails: false)
        var stored = try #require(try store.meeting(m.id))
        #expect(stored.people.map(\.name) == ["Zoe", "Alex Martin", "Dana Whitfield"] && stored.linkedEvent?.unnamedAttendees == 1)
        #expect(stored.people.allSatisfy { $0.email == nil })
        #expect(try !store.search("Dana").isEmpty, "calendar people are searchable like typed ones")
        try store.setLinkedEvent(nil, for: m.id)
        stored = try #require(try store.meeting(m.id))
        #expect(stored.linkedEvent == nil && stored.people.map(\.name) == ["Zoe", "Alex Martin", "Dana Whitfield"], "unlink keeps every person")
        try CalendarLinking.link(a, to: m.id, in: store, keepEmails: false)
        #expect(try store.meeting(m.id)?.people.count == 3, "re-linking adds no duplicates")
        try CalendarLinking.link(b, to: m.id, in: store, keepEmails: false)
        stored = try #require(try store.meeting(m.id))
        #expect(stored.people.map(\.name) == ["Zoe", "Alex Martin", "Dana Whitfield", "Ravi Patel"] && stored.linkedEvent?.identifier == "b")
        #expect(stored.people.first == Person(name: "Zoe"), "manual people are never touched")
    }
}
