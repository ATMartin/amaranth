import Testing
import Foundation
import Domain
import Storage
@testable import Presentation

@Suite("Calendar linking (T57)")
struct CalendarLinkingTests {
    static let t = Date(timeIntervalSinceReferenceDate: 800_000_000)
    static func ev(_ id: String, _ title: String, _ start: Double, _ minutes: Double = 30, allDay: Bool = false, cancelled: Bool = false,
                   calendar: String? = "Work", attendees: [CalendarAttendee] = []) -> CalendarEvent {
        CalendarEvent(identifier: id, title: title, start: t.addingTimeInterval(start * 60), end: t.addingTimeInterval((start + minutes) * 60),
                      isAllDay: allDay, isCancelled: cancelled, calendarName: calendar, attendees: attendees)
    }

    @Test func snapshotMapsTheSpecFields() {
        let e = Self.ev("ext-1", "Roadmap sync", 0)
        #expect(CalendarLinking.snapshot(e) == LinkedEvent(identifier: "ext-1", title: "Roadmap sync", start: e.start, end: e.end,
                                                           calendarName: "Work", source: .eventKit))
    }

    @Test func pickerPutsTheNearestFirstAndAllDayLast() {
        let events = [Self.ev("a", "Early", -180), Self.ev("b", "In progress", -10), Self.ev("c", "Soon", 20), Self.ev("d", "Offsite", -600, 1440, allDay: true),
                      Self.ev("e", "Cancelled", -5, cancelled: true), Self.ev("f", "Later", 240)]
        #expect(CalendarLinking.pickerEvents(events, recordedAt: Self.t).map(\.identifier) == ["b", "c", "a", "f", "d"])
    }

    @Test func searchMatchesTitleCalendarAndAttendees() {
        let events = [Self.ev("a", "Roadmap sync", 0, attendees: [CalendarAttendee(name: "Dana Whitfield")]), Self.ev("b", "Café chat", 60, calendar: "Home")]
        #expect(CalendarLinking.filter(events, query: "road").map(\.identifier) == ["a"])
        #expect(CalendarLinking.filter(events, query: "dana").map(\.identifier) == ["a"])
        #expect(CalendarLinking.filter(events, query: "cafe").map(\.identifier) == ["b"], "accents ignored")
        #expect(CalendarLinking.filter(events, query: "home").map(\.identifier) == ["b"])
        #expect(CalendarLinking.filter(events, query: "  ").count == 2)
    }

    @Test func liveStatusCurrentChangedMissingUnknown() {
        let e = Self.ev("x", "Roadmap sync", 0)
        let linked = CalendarLinking.snapshot(e)
        #expect(CalendarLinking.liveStatus(of: linked, in: [e], access: .fullAccess) == .current)
        var renamed = e; renamed.title = "Roadmap review"
        #expect(CalendarLinking.liveStatus(of: linked, in: [renamed], access: .fullAccess) == .changed(renamed))
        let moved = Self.ev("x", "Roadmap sync", 60)
        #expect(CalendarLinking.liveStatus(of: linked, in: [moved], access: .fullAccess) == .changed(moved), "a moved occurrence is the same event")
        #expect(CalendarLinking.liveStatus(of: linked, in: [Self.ev("x", "Roadmap sync", 7 * 1440)], access: .fullAccess) == .missing,
                "next week's occurrence of a recurring event is not this one")
        #expect(CalendarLinking.liveStatus(of: linked, in: [], access: .fullAccess) == .missing)
        #expect(CalendarLinking.liveStatus(of: linked, in: [Self.ev("x", "Roadmap sync", 0, cancelled: true)], access: .fullAccess) == .missing)
        #expect(CalendarLinking.liveStatus(of: linked, in: [e], access: .denied) == .unknown)
    }

    @Test func chipStates() {
        let linked = CalendarLinking.snapshot(Self.ev("x", "Roadmap sync", 0))
        #expect(CalendarChip.state(linked: nil, access: .notDetermined, live: .unknown) == .link(asks: true))
        #expect(CalendarChip.state(linked: nil, access: .fullAccess, live: .unknown) == .link(asks: false))
        #expect(CalendarChip.state(linked: nil, access: .denied, live: .unknown) == .accessOff)
        #expect(CalendarChip.state(linked: nil, access: .writeOnly, live: .unknown) == .accessOff)
        #expect(CalendarChip.state(linked: nil, access: .restricted, live: .unknown) == .managed)
        #expect(CalendarChip.state(linked: linked, access: .denied, live: .missing) == .linked(linked, .unknown), "a stored link shows without access")
        let utc = TimeZone(identifier: "UTC")!, en = Locale(identifier: "en_US")
        #expect(CalendarLinking.chipLabel(linked, timeZone: utc, locale: en).hasPrefix("Roadmap sync · "))
        #expect(CalendarChip.linked(linked, .changed(Self.ev("x", "New", 0))).needsAttention)
        #expect(CalendarLinking.tooltip(linked, status: .missing).contains("No longer in your calendar"))
        #expect(CalendarLinking.tooltip(linked, status: .current).contains("Calendar: Work"))
    }

    @Test func useEventTitleIsOfferedNotApplied() {
        var m = Meeting(title: "My title", createdAt: Self.t)
        #expect(!CalendarLinking.offersEventTitle(m))
        m.linkedEvent = CalendarLinking.snapshot(Self.ev("x", "Roadmap sync", 0))
        #expect(CalendarLinking.offersEventTitle(m) && m.title == "My title")
        m.title = "Roadmap sync"
        #expect(!CalendarLinking.offersEventTitle(m))
    }

    /// Linking persists, `linked_event_id` finds the other recordings of the same occurrence (not other occurrences),
    /// and unlinking clears it.
    @Test func linkPersistsAndAlsoLinked() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "amr-link-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let a = Meeting(title: "A", createdAt: Self.t), b = Meeting(title: "B", createdAt: Self.t), c = Meeting(title: "C", createdAt: Self.t)
        for m in [a, b, c] { try store.upsertMeeting(m) }
        let e = CalendarLinking.snapshot(Self.ev("weekly", "Weekly", 0))
        let nextWeek = CalendarLinking.snapshot(Self.ev("weekly", "Weekly", 7 * 1440))
        try store.setLinkedEvent(e, for: a.id); try store.setLinkedEvent(e, for: b.id); try store.setLinkedEvent(nextWeek, for: c.id)
        let linked = try store.meetings(linkedTo: "weekly")
        #expect(linked.count == 3)
        let stored = try #require(try store.meeting(a.id))
        #expect(stored.linkedEvent == e)
        #expect(CalendarLinking.alsoLinked(stored, among: linked).map(\.title) == ["B"])
        try store.setLinkedEvent(nil, for: b.id)
        #expect(try store.meetings(linkedTo: "weekly").map(\.title).sorted() == ["A", "C"])
    }
}
