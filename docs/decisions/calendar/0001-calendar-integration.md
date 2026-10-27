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

## T57 — the header chip

- **States.** `CalendarChip.state` decides: a stored link always shows (title and time), even without access, because
  the snapshot is ours; with access it is compared with the calendar (`CalendarLinking.liveStatus`): same occurrence
  (identifier + start), else the same identifier's nearest occurrence within a day (a moved meeting → "changed");
  nothing → "No longer in your calendar". Next week's occurrence of a recurring event never counts as this one.
  Unlinked: "Link calendar event…" (asks on click), "Link calendar event" (picker), "Calendar access is off" (popover
  with Open Privacy Settings), or the inert dashed chip when an administrator restricts access.
- **Prompt while recording.** If access was never decided and a recording is running, the click explains that
  Amaranth asks after the recording, instead of prompting.
- **Picker.** The recording's local day; timed events nearest to the recording's start first (zero distance while
  inside the event), all-day events last, cancelled ones hidden, declined ones marked. Search covers the title,
  calendar and attendee names.
- **Also linked to.** `MeetingStore.meetings(linkedTo:)` over the `linked_event_id` index, filtered to the same
  occurrence start.
- **Narrow windows.** The header has a third, narrowest variant in which a linked event shows as its icon only.
