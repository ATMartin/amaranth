# Calendar 0001 — How Milestone O implements the calendar spec

Date: 2026-10-27 · Spec: `docs/decisions/0006-calendar-integration-spec.md` (accepted). This note records the
implementation choices the spec left open, task by task.

## T56 — access and a testable source

- **Where the code lives.** The `CalendarSource` protocol, the value types (`CalendarEvent`, `CalendarAttendee`,
  `CalendarInfo`, `CalendarAuthorization`) and `FakeCalendarSource` are in the `Presentation` package module, so the
  rules are covered by `swift test`. The task's `App/Calendar/` holds only what needs EventKit or SwiftUI:
  `EventKitCalendarSource` and the `@Observable CalendarModel`.
- **What is read.** Title, start/end, all-day, status (cancelled), recurrence, calendar id/name and attendees (name,
  `mailto:` address, type, response, `isCurrentUser`). Notes, location, URL and conference links are never copied
  out of EventKit. The email is read so the off-by-default "Keep attendee email addresses" setting (T61) can work;
  it is dropped before anything is stored unless that setting is on (T58).
- **When a prompt can appear.** `CalendarAccessTrigger.mayRequest` allows it only for a user action while not
  recording, and only while the status is not determined. `CalendarModel` reads the status at init
  (`EKEventStore.authorizationStatus`, which never prompts) and creates the `EKEventStore` lazily.
- **Self-test.** `--self-test calendar-access` asks (if undecided) and reads three days of events, logging counts
  only, never titles or names. It needs a person, like the capture trials, and is listed in `scripts/check.sh`.
