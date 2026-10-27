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

## T58 — attendees become people

- **One link path.** `CalendarLinking.link` (header chip, Update, and T59's approved suggestion) writes the snapshot
  and the merged people in one `MeetingStore.linkEvent` transaction, then re-indexes people for search.
- **Who becomes a person.** Attendees of kind person (or unknown) with a display name. Rooms, resources and groups
  (mailing lists) never do. Attendees without a name are counted in `LinkedEvent.unnamedAttendees` (optional, so
  existing JSON is unchanged) and shown as "· 2 unnamed" on the people chip; nothing else about them is stored.
- **Order and merging.** People already on the meeting keep their place, name, source and email; new attendees are
  appended as `.calendar`, the current user first. Matching ignores case. Unlinking only clears the link.
- **Emails.** `Person.email` (optional) is filled only when "Keep attendee email addresses" is on
  (`CalendarSettings.keepEmailsKey`, off by default; the switch itself is in Settings → Calendar, T61). The people
  editor keeps a stored email when the name is kept. JSON exports drop emails, so exports carry only the T49 fields.
- **"Changed" ignores attendees.** The live comparison looks at identifier, title, times and calendar only.

## T59 — the suggestion at Record

- **Matching** (`CalendarSuggestion.candidates`): events in progress, or starting within 10 minutes inclusive; all-day,
  cancelled and declined ones ignored; in-progress first (latest start first), then upcoming (soonest first); a
  reminder's event (T61) first. Read from the calendar only after capture has started, only with access already
  granted and the setting on (default on), and never asks for access.
- **Only a question.** `RecorderModel.approve(_:)` is the one place a suggestion links, and only a button in the
  prompt calls it. Approval goes through `CalendarSuggestion.approve` → `CalendarLinking.link` (attendees merge as in
  T58); the event title replaces the meeting title only if it is still the automatic title it got at Record.
- **Deviation from the spec's layout.** The spec asked for "<title>?" with Link / Not this inline in the strip. At a
  900 pt window with the sidebar open, the detail toolbar has about 75 pt to spare, so inline buttons pushed Export
  and Delete into the overflow menu (measured by the ui-render toolbar check). The strip therefore shows one compact
  button, "📅 <title>?" (one match) or "📅 Which event?" (several), truncated to 74 pt. Clicking it opens the full
  question with the time and calendar, and Link / Not this (or each event and None). Ignoring it changes nothing.
- **Rename races.** The recording session used to re-save its own copy of the meeting, title included, on every state
  change, which would undo an approved rename (and any rename made while recording). `upsertMeeting(_:keepingStoredTitle:)`
  now keeps the stored title for the session's updates.
- **Settings → Calendar** starts here with the access row and "Suggest calendar events when recording"; turning it on
  is a user action and may show the prompt (never while recording).
