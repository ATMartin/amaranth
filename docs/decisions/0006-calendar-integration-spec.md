# 0006 — Calendar integration spec (EventKit, the Mac's own calendars)

Date: 2026-10-26 · Status: **Accepted 2026-10-27** (T51), with the user's three answers applied (see "Decisions"
at the end). Tasks T56–T61 (Milestone O) are in `docs/implementation-tasks.json`; Milestone O is not yet placed in
the milestone order.

> 2026-10-27: spec [0007](0007-google-calendar-integration-spec.md) (proposed) would add a direct Google Calendar
> integration and, if accepted, amend this spec's "No cloud calendar APIs" non-goal and its Approach.

Source: design review of 2026-10-23, 10:24–11:15 (`docs/design-review/2026-10-23/transcript.md`): "I would eventually
like to be able to link an Amaranth recording to a calendar event and let that automatically populate the name of the
meeting … We also show the people in the meeting … We should think about speccing out a milestone for it." Reference:
`granola-note-header-calendar-people.png`. Data shape: T49 (`Meeting.people`, `Meeting.linkedEvent`). UI placeholder:
T50 (the disabled "Link calendar event" chip).

## Approach

Read the calendars the user has already added to macOS (iCloud, Google, Exchange, CalDAV, local) through **EventKit**,
after a one-time system permission prompt. Amaranth gets no account, token, or network access of its own. Granola
instead talks to Google Calendar's API, which needs an account integration and a server; that is against Amaranth's
local-only principle, so we don't do it.

## Goals

1. **Link a recording to an event.** In the meeting header, the T50 chip opens a picker showing events from the
   recording's day, nearest to the recording's start first, with a search field. Picking one stores a `LinkedEvent`
   snapshot. "Unlink" removes it.
2. **Suggested event at Record — always asks.** When recording starts, find the events that best overlap now: an
   event in progress, or one starting within the next 10 minutes. Ignore all-day, declined and cancelled events.
   **Nothing is linked or renamed without the user's explicit approval**, even with exactly one match: meetings get
   cancelled at the last minute and unplanned calls pop up, so a lone match is not proof. The recording strip shows a
   one-line prompt — one match: "Roadmap sync?" with Link / Not this; several: "Which meeting?" with the choices and
   None. Ignoring it changes nothing; the prompt can be dismissed and the event linked later from the header chip.
   Approving links the event; the meeting takes the event's title only if it still has its automatic title
   (`RecorderPresentation.automaticTitle`, i.e. the user typed none). A meeting the user has titled or renamed is
   never renamed; the header chip offers "Use event title" instead.
3. **Attendees as people.** Linking adds the event's named attendees to `Meeting.people` with `source: .calendar`,
   skipping rooms and resources (`EKParticipant.participantType == .room / .resource`). Manual entries are never
   removed or renamed. **Unlinking leaves all people in place**, calendar-sourced ones included: the user removes any
   they don't want through the people editor (control over convenience). Re-linking the same or another event merges
   its attendees in again without duplicating names already there.
4. **Speaker-rename suggestions.** The existing speaker rename popover (TranscriptPane) lists the meeting's people as
   one-click suggestions above the free-text field. Speakers are never named automatically: diarization labels are
   anonymous, and guessing a name could put words in the wrong person's mouth.
5. **Optional "meeting starting" reminder** (off by default). A local notification about a minute before an event in
   the calendars the user picked: "Roadmap sync starts in 1 min — Record". Clicking it brings Amaranth forward with that
   event offered first in the next recording's prompt (still approved by the user, per Goal 2). **It never starts a
   recording.** Kept in Milestone O as an experiment; the user may drop it or split follow-up work into a new
   milestone after seeing it.

## Explicit non-goals

- No automatic recording start, in any form. Recording always begins with the user pressing Record (consent text
  unchanged).
- No meeting bot, and no joining or dialing into calls.
- No cloud calendar APIs (Google, Microsoft Graph), no OAuth, and no network access for this feature.
- No writing to calendars: no creating events, adding notes to events, or attaching links.
- No live sync. The link is a snapshot taken at link time; see "Data mapping".

## Permission flow

- **Info.plist:** `NSCalendarsFullAccessUsageDescription` ("Amaranth reads your calendar to name recordings and list
  who was invited. Nothing leaves this Mac."). The task text asked for `NSCalendarsUsageDescription`, but that is the
  pre-macOS 14 key; our minimum is macOS 26.5, where reading events needs *full* access. Write-only access can't read
  events.
- **Entitlement:** `com.apple.security.personal-information.calendars` in `App/Amaranth.entitlements`, required
  under the hardened runtime (the app is not sandboxed).
- **When we ask:** only when the user acts: the first click on the chip, or turning on "Suggest calendar events when
  recording" or the reminder in Settings. Never at launch, and never in the middle of a recording. (Remember from
  Milestone A that system prompts can stall capture start; we must not stack one on top of Record.)
- **API:** `EKEventStore.requestFullAccessToEvents()`. Check status with `EKEventStore.authorizationStatus(for: .event)`:
  - `.notDetermined` → the chip reads "Link calendar event…" and asks on click.
  - `.fullAccess` → the picker.
  - `.denied` → the chip reads "Calendar access is off", with a popover explaining why and an "Open Privacy
    Settings" button (`x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars`). No retry loop:
    macOS won't show the prompt twice.
  - `.restricted` (MDM) → the chip is disabled with a tooltip saying the administrator controls calendar access.
  - `.writeOnly` → treated like denied, since we can't read events.
- **Ad-hoc signing:** every rebuild changes the signature, so TCC may ask again on dev builds, just as it does for the
  microphone. Hardware/permission checks need a person and are batched like the capture trials.

## Data mapping onto T49

| `LinkedEvent` field | EventKit source | Notes |
|---|---|---|
| `identifier` | `calendarItemExternalIdentifier`, falling back to `eventIdentifier` | The external ID survives sync and stays the same across devices; recurring occurrences share it, so `start` tells them apart. |
| `title` | `EKEvent.title` | Snapshot. If the event is renamed later, the meeting keeps its own title. |
| `start`, `end` | `startDate`, `endDate` of the chosen occurrence | Stored as absolute dates (UTC in JSON). |
| `calendarName` | `EKEvent.calendar.title` | Shown in the chip's tooltip; may be nil. |
| `source` | `.eventKit` | The only source planned. |

- Use the `linked_event_id` column (schema v3) to check "already linked to another recording?" and show "Also linked
  to: <meeting>". Several recordings of one event are allowed (a call that dropped and restarted).
- `Person` from `EKParticipant.name`, with `source: .calendar`, de-duplicated against existing people
  (case-insensitive), with the current user (`isCurrentUser`) listed first.
- The meeting title only changes under Goal 2's rule, after the user approves the link. Linking later from the chip
  offers "Use event title" as a button; it never renames silently.
- **Refresh:** none automatic. The picker shows "Event changed since linking" when the stored snapshot differs from
  the live event, with an "Update" button. A deleted event leaves the snapshot in place, marked "no longer in your
  calendar".

## Privacy

- Nothing leaves the Mac. EventKit reads the local calendar database that macOS syncs; Amaranth makes no network
  calls for this feature, and nothing extra goes into exports beyond the T49 fields.
- **Attendee emails are never stored** unless the user turns on "Keep attendee email addresses" (off by default,
  in Settings → Calendar). Attendees with no display name are skipped, and the chip shows "+2 unnamed". We don't fall
  back to the email's local part, because that would store part of the email anyway.
- Event notes, location, URLs and conference links are not read into storage. The notes model never sees calendar
  data beyond the people names, and only once T53/T55 index or cite them.
- Deleting a meeting deletes its linked-event snapshot and calendar-sourced people along with it, through the existing
  tombstone and complete-deletion path. A data-lifecycle test should prove the event title disappears from the database
  bytes.
- Turning calendar access off in System Settings doesn't erase links already stored. Settings → Calendar gets
  "Remove calendar data from all meetings" for that.

## UI placement

- **Meeting header (T50):** the `link` chip becomes active. When unlinked it reads "Link calendar event"; when linked
  it shows the event title and time ("Roadmap sync · 10:00–10:30"), with the calendar name in the tooltip. Clicking it
  opens the picker / Unlink / Update popover. The people chip is unchanged; calendar-sourced names show a small
  calendar glyph in its editor.
- **Recording strip:** only the one-line approval prompt from Goal 2 ("Roadmap sync?" or "Which meeting?"), shown
  whenever there is at least one match; it must fit the strip without pushing Stop/Save into the toolbar overflow.
  The Recording tab stays out of scope.
- **Settings → Calendar (new section):** "Suggest calendar events when recording" (on after access is granted), the
  reminder toggle and calendar list, "Keep attendee email addresses" (off), and "Remove calendar data from all
  meetings".

## Testing approach

- Put EventKit behind a small protocol (`CalendarSource`: authorization status, events in a range) so matching rules,
  mapping and privacy filtering can be unit-tested with a fake. EventKit itself is exercised only in a permission
  self-test that needs a person, like the capture trials.
- `--self-test ui-render` gains fixtures for each chip state: not determined, denied, restricted, linked, changed.
- Matching rules get table tests: in progress, starts in 9 vs 11 min, overlapping invitations, all-day, declined,
  recurring occurrence.

## Proposed task breakdown (Milestone O, pending review)

| Task | Title | Depends on |
|---|---|---|
| T56 | Calendar access: Info.plist key, entitlement, `CalendarSource` protocol + EventKit implementation, authorization states, permission self-test | T49 |
| T57 | Link/unlink from the header chip: event picker for the recording's day, snapshot mapping, "Use event title", "changed"/"no longer in calendar" states, ui-render fixtures | T56, T50 |
| T58 | Attendees as people: participant filtering (rooms, unnamed, current user), merge rules with manual people, unlink keeps people, deletion-bytes test | T57 |
| T59 | Suggest the event at Record: matching rules, approval prompt in the recording strip for one or several matches (never links on its own), automatic title only when untitled | T57 |
| T60 | Speaker-rename suggestions from the meeting's people | T58 |
| T61 | Optional "meeting starting" reminder (local notification, off by default, never starts recording) and Settings → Calendar section | T56 |

The order is T56 → T57 → T58 → (T59, T60, T61 in any order). T59 and T60 deliver most of the value; T61 can be dropped
without affecting the rest.

## Decisions (user, 2026-10-27)

1. **Automatic title → always ask.** "I frequently have meetings canceled at the last minute or unplanned calls that
   pop up - I need an explicit approval step to ensure they don't get mislabeled." Applied to Goal 2 and T59.
2. **Reminder (T61) → keep.** "I'm curious to see how you implement it. I may remove it before completing this
   milestone or break additional work into a new milestone if needed." Applied to Goal 5 and T61.
3. **Unlinking → keeps calendar-sourced people.** "If I disassociate a calendar invite, I can also disassociate the
   people who came with it selectively … for now I'm optimizing for control over convenience." Applied to Goal 3 and
   T58.
