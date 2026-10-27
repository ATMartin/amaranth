import Testing
import Foundation
@testable import Presentation

@Suite("Meeting-starting reminder (T61)")
struct CalendarReminderTests {
    static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    static func ev(_ id: String, start minutes: Double, calendar: String = "work", allDay: Bool = false, cancelled: Bool = false,
                   declined: Bool = false) -> CalendarEvent {
        CalendarEvent(identifier: id, title: id, start: now.addingTimeInterval(minutes * 60), end: now.addingTimeInterval((minutes + 30) * 60),
                      isAllDay: allDay, isCancelled: cancelled, calendarID: calendar,
                      attendees: declined ? [CalendarAttendee(name: "Me", response: .declined, isCurrentUser: true)] : [])
    }
    static let events = [ev("soon", start: 5), ev("now", start: 0.5), ev("home", start: 20, calendar: "home"), ev("offsite", start: 60, allDay: true),
                         ev("gone", start: 30, cancelled: true), ev("skip", start: 40, declined: true), ev("tomorrow", start: 23 * 60),
                         ev("too-far", start: 25 * 60), ev("later", start: 90)]

    @Test func planChosenCalendarsOneMinuteAhead() {
        let plan = CalendarReminder.plan(Self.events, now: Self.now, calendars: ["work"])
        #expect(plan.map(\.eventIdentifier) == ["soon", "later", "tomorrow"], "the 30 s event's reminder time has passed")
        #expect(plan[0].fireDate == Self.now.addingTimeInterval(4 * 60) && plan[0].headline == "soon starts in 1 min")
        #expect(CalendarReminder.plan(Self.events, now: Self.now, calendars: ["work", "home"]).map(\.eventIdentifier) == ["soon", "home", "later", "tomorrow"])
        #expect(CalendarReminder.plan(Self.events, now: Self.now, calendars: []).isEmpty)
        #expect(CalendarReminder.body.contains("never starts recording"))
    }

    @Test func syncSchedulesRemovesStaleAndTurningOffClearsAll() async {
        let source = FakeCalendarSource(status: .fullAccess, events: Self.events)
        let scheduler = FakeReminderScheduler(otherPending: ["someone-else"])
        await CalendarReminders.sync(enabled: false, calendars: ["work"], source: source, scheduler: scheduler, now: Self.now)
        #expect(scheduler.scheduled.isEmpty, "off by default: nothing scheduled")
        await CalendarReminders.sync(enabled: true, calendars: ["work"], source: source, scheduler: scheduler, now: Self.now)
        #expect(scheduler.scheduled.map(\.eventIdentifier) == ["soon", "later", "tomorrow"])
        // An event is cancelled: its reminder goes on the next sync; the others stay.
        source.setEvents(Self.events.map { $0.identifier == "later" ? Self.ev("later", start: 90, cancelled: true) : $0 })
        await CalendarReminders.sync(enabled: true, calendars: ["work"], source: source, scheduler: scheduler, now: Self.now)
        #expect(scheduler.scheduled.map(\.eventIdentifier) == ["soon", "tomorrow"])
        // Turning it off removes every pending Amaranth reminder, and nothing else.
        await CalendarReminders.sync(enabled: false, calendars: ["work"], source: source, scheduler: scheduler, now: Self.now)
        #expect(scheduler.scheduled.isEmpty && scheduler.foreignIDs == ["someone-else"])
    }

    @Test func noAccessOrNoCalendarsSchedulesNothing() async {
        let scheduler = FakeReminderScheduler()
        await CalendarReminders.sync(enabled: true, calendars: ["work"], source: FakeCalendarSource(status: .fullAccess, events: Self.events),
                                     scheduler: scheduler, now: Self.now)
        #expect(!scheduler.scheduled.isEmpty)
        await CalendarReminders.sync(enabled: true, calendars: ["work"], source: FakeCalendarSource(status: .denied, events: Self.events),
                                     scheduler: scheduler, now: Self.now)
        #expect(scheduler.scheduled.isEmpty, "access turned off in System Settings: reminders go")
        await CalendarReminders.sync(enabled: true, calendars: [], source: FakeCalendarSource(status: .fullAccess, events: Self.events),
                                     scheduler: scheduler, now: Self.now)
        #expect(scheduler.scheduled.isEmpty)
    }

    @Test func reminderEventIsOfferedFirstAtRecord() {
        let events = [Self.ev("running", start: -5), Self.ev("reminded", start: 1)]
        #expect(CalendarSuggestion.candidates(events, at: Self.now, preferred: "reminded").map(\.identifier) == ["reminded", "running"])
    }
}
