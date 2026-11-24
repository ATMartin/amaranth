import Testing
import Foundation
@testable import Presentation

@Suite("Calendar access (T56)")
struct CalendarAccessTests {
    @Test func statesMapPerTheSpec() {
        #expect(CalendarAuthorization.notDetermined.presentation == .askOnClick)
        #expect(CalendarAuthorization.fullAccess.presentation == .ready)
        #expect(CalendarAuthorization.denied.presentation == .off)
        #expect(CalendarAuthorization.writeOnly.presentation == .off, "write-only can't read events: treated like denied")
        #expect(CalendarAuthorization.restricted.presentation == .managed)
        #expect(CalendarAuthorization.allCases.filter(\.canRead) == [.fullAccess])
    }

    /// Only a user action outside a recording may show the prompt, and only while undecided.
    @Test func onlyUserActionsMayPrompt() {
        for status in CalendarAuthorization.allCases {
            #expect(!CalendarAccessTrigger.launch.mayRequest(status))
            #expect(!CalendarAccessTrigger.recordingStarted.mayRequest(status))
            #expect(!CalendarAccessTrigger.userAction(recording: true).mayRequest(status))
            #expect(CalendarAccessTrigger.userAction(recording: false).mayRequest(status) == (status == .notDetermined))
        }
    }

    @Test func fakeAsksOnceAndReadsOnlyWithFullAccess() async {
        let day = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let e = CalendarEvent(identifier: "e1", title: "Sync", start: day, end: day.addingTimeInterval(1800))
        let fake = FakeCalendarSource(status: .notDetermined, answer: .fullAccess, events: [e])
        #expect(fake.events(from: day.addingTimeInterval(-60), to: day.addingTimeInterval(60), calendarIDs: nil).isEmpty)
        #expect(fake.requests == 0, "creating a source never prompts")
        #expect(await fake.requestAccess() == .fullAccess)
        #expect(fake.events(from: day.addingTimeInterval(-60), to: day.addingTimeInterval(60), calendarIDs: nil) == [e])
        #expect(fake.events(from: day.addingTimeInterval(1800), to: day.addingTimeInterval(3600), calendarIDs: nil).isEmpty, "end is exclusive")
        #expect(fake.events(from: day, to: day.addingTimeInterval(60), calendarIDs: ["other"]).isEmpty)
        let denied = FakeCalendarSource(status: .notDetermined, answer: .denied, events: [e])
        #expect(await denied.requestAccess() == .denied)
        #expect(await denied.requestAccess() == .denied, "a decided status stays: no second prompt")
        #expect(denied.calendars().isEmpty)
    }

    @Test func declinedAndOccurrenceIdentity() {
        let day = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let me = CalendarAttendee(name: "Me", response: .declined, isCurrentUser: true)
        let a = CalendarEvent(identifier: "r", title: "Weekly", start: day, end: day.addingTimeInterval(1800), isRecurring: true, attendees: [me])
        let b = CalendarEvent(identifier: "r", title: "Weekly", start: day.addingTimeInterval(7 * 86_400), end: day.addingTimeInterval(7 * 86_400 + 1800), isRecurring: true)
        #expect(a.declinedByMe && !b.declinedByMe)
        #expect(a.id != b.id, "recurring occurrences share the identifier but not the id")
    }
}
