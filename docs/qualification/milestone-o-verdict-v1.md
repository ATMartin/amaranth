# Milestone O validation verdict

**PASS WITH FIXES** (no must-fix blockers; a few should-fix items, mostly small).

## Must-fix
None.

## Should-fix
1. T61 `ReminderController.enable()` calls the notification `requestAuthorization` even while recording (only the calendar request is guarded). A system notification prompt mid-recording contradicts the "never prompt during a recording" rule; guard it with `recorder.inSession` (defer until after) .
2. Reminder staleness: pending id = prefix + identifier@start, so a retitled event (same start) keeps its old notification text until it fires/expires. Include title in the id or compare content.
3. Linked meeting while access is undecided: LinkedEventDetails shows "Calendar access is off, so Amaranth can't check..." for notDetermined (not off), and Change Event is hidden with no way to grant from the chip. Wording/CTA should differ (Settings has Allow Access).
4. `CalendarSuggestion.approve` re-upserts a full meeting row read from the store (title step) while the session may persist concurrently; a stale capture-state/duration could be written for one tick (session re-persists later, so self-heals). Prefer a title-only store update.
5. Settings window is too short for the Calendar tab at default size; "Remove Calendar Data..." is clipped below the fold (scroll needed).
6. "Changed since linking" popover shows only the stored values; the new title/time is only in the Update tooltip. Show the new values inline.
7. Not covered by "Remove calendar data": speaker names the user chose from a calendar person (T60) remain, by design (user edits); worth one sentence in the Settings help text.
8. Notification text carries the event title (visible on lock screen); mention in Settings or accept.
9. `--self-test ui-render --self-test-output <dir>` (as written in the brief/check.sh) logs nothing because the output handle expects a file; pass/fail is only visible on stdout when run directly. Not new in O.

## Needs a person
- Real Link flow with a real invite (no event existed on any real meeting date; 0 events in 3 days; calendar-access self-test: 3 calendars, 0 events).
- Notification permission prompt and a reminder click (never starts recording), reminder with real calendars.
- Record-time prompt end to end (press Record, Link / Not this / Which event?), and Stop afterwards keeps the approved title.
- Speaker Rename: clicking a suggestion chip saves (unit-tested to be the identical edit; not clicked).
- Narrow-window header and toolbar at 900 pt on the real library (ui-render covers it).
- Removing calendar data / turning emails off on real data (bytes tests pass).

## Real-library changes and revert
No change was made to the real library. I opened the picker for each of the 3 live meetings (all empty: "No events in your calendars that day"), viewed Settings → Calendar, and did not link, rename, export or press any destructive button. Verified with sqlite3 -readonly: sha of (id, json) over all rows identical before/after (196388a9...), linked_event_id null for all rows, no people.
Defaults changed: only `com_apple_SwiftUI_Settings_selectedTabIndex` 2 -> 3 (opening the Calendar settings tab); no calendar* keys exist. App quit with Cmd+Q (PID 50986); nothing left running.

## What I checked
- Tests: swift test with the brief's filter: all passed (Calendar access, Linking, People, Suggestion, Reminder, Rename suggestions, DataLifecycle incl. deletion-bytes and remove-data tests, MeetingStore, Contract).
- ui-render (run directly, stdout): `{"result":"pass"}`, exit 0; toolbar-recording at 900/1100 with none/one/several prompts: items 8, hidden "" in all. Viewed chip states, popovers, toolbar-900 with prompt, settings (reminder on), rename sheet, event prompt choices.
- T56: Info.plist NSCalendarsFullAccessUsageDescription and entitlement present in built app. Every requestAccess/request call site read: chip click (only when unlinked), Settings toggle/Allow button, reminder enable, self-test; all go through CalendarModel.request -> CalendarAccessTrigger (launch/recording never; recording=true blocked). Launch only reads status and sets the notification delegate. writeOnly -> off, restricted -> managed, tested.
- T57: states, picker ordering/search code, snapshot mapping (external id fallback), Update/missing/also-linked, Use Event Title is a button only, JSON export carries the link (ui-render).
- T58: merge rules tests (rooms/resources/groups/unnamed skipped, current user first among added, manual untouched, re-link no duplicates), unlink keeps people, emails only with setting and stripped from JSON export, bytes tests.
- T59: matching table incl. 9/10/11 min, overlap, all-day, declined, cancelled, recurring. Proved by code reading: the only path to a link at Record is RecorderModel.approve, called only from prompt buttons; offerEvents only sets eventPrompt. Chip/Update go through user buttons. upsertMeeting(keepingStoredTitle:) is used only by RecordingSession.persistMeeting; all other upsert callers (rename, tombstone, recovery, processing) are unchanged and still set the title; behavior change is the intended fix. Deviation (compact button + popover): ACCEPTABLE: still an explicit approval, one extra click, keeps Export/Delete visible at 900 pt as measured.
- T60: suggestion fills field and runs same Save (test + code); renders with/without people. Click not performed by me.
- T61: plan/sync/off/no-access/foreign-id tests pass; notification permission only in enable(); click sets preferredEventID and opens window, never records; settings contents verified hands-on and in renders (reminder off by default, emails off).
- Privacy: no URLSession/network or EKEventStore save/remove in the calendar code; EventKit mapping copies no notes/location/URL; email read only to be dropped unless the opt-in is on.
- Regressions: header chips, people chip, strip without prompt render fine; exports of unlinked meetings unchanged (optional fields omitted, tests pass).
