# Milestone M verdict: PASS WITH FIXES

## Must-fix
None.

## Should-fix
1. purgeMeeting (Storage/Deletion/Deletion.swift) scrubs the meeting JSON, which drops people and the linked event. It does not reset the new `linked_event_id` column, though. After complete deletion the provider event identifier would stay in the row and the index. Nothing writes the column yet, so there is no leak today. T49 added the column and no lifecycle test proves people and event are gone from the database bytes (T58 plans that test). Add `linked_event_id=NULL` to the purge UPDATE, plus a purge test.
2. Narrow window (720 pt wide, wide sidebar): the header chips truncate. The date chip shows "Oct 22, 2..." and the people chip "Ana Rui...". The "Link cal..." placeholder also truncates. The row does not wrap or give priority. Drop the placeholder's text first, or let the chips wrap or scroll, or give the date chip a layout priority. Nothing overlaps or breaks; only legibility is lost.
3. The inert calendar chip is an AXUnknown element. Through System Events it shows no description or help. The accessibilityLabel and value are probably exposed (an AXValueDescription attribute exists), but I could not confirm this without VoiceOver. The tooltip "Calendar linking is planned" does show on hover.

## Nits
- The people popover's TextEditor shows a scroll gutter with 3 lines (Dark and Light).
- Spec 0006 says unlink removes ".calendar people the user hasn't edited". Person has no edited flag. MeetingPeople.parse keeps the source by name, so a renamed calendar person turns manual. This works, but T58 should say so.

## Needs a person
- Checklist item 43 (recording-dependent): a recording keeps people, and the header holds up while recording. The stale-writer unit test covers upsert, but a live check is needed.
- VoiceOver: people chip announcement ("People: ..." plus the hint), and the calendar chip reading "Link calendar event, not available yet".
- Keyboard Tab order, to confirm focus skips the calendar chip. Via AX the header has only one button (the people chip).
- Light and Dark visual pass of the popover in real use. I checked both appearances, but only by screenshot.

## What I checked
- Tests: `swift test --filter "MeetingStoreTests|ExportTests|MeetingPeopleTests|ContractRoundTrip"` passed, 27 tests. `--self-test ui-render` returned `pass`. I viewed main-* and people-editor* in Light and Dark; chips and editor render correctly, with names on the two-hour fixture and "Add people..." elsewhere.
- T49 code review:
  - Person (name, source manual|calendar) and LinkedEvent (identifier, title, start, end, calendarName, source eventKit) match the deliverable.
  - ContractVersion.current stays 1.
  - Meeting decode defaults people to [] and linkedEvent to nil. Encode omits people when empty, so JSON is unchanged without metadata.
  - Migration v3 is `ALTER TABLE ADD COLUMN` plus an index under the user_version gate, so it is idempotent. The real library went v2 to v3 on first launch: 6 rows decode, 0 linked_event_id values, 0 people.
  - upsertMeeting keeps the stored people and event on an existing row, and a first insert uses the caller's values. The only way to change people is the setters.
  - The other writers (publishSummary, publishTranscript) re-read the row JSON in the same transaction, so they keep people.
  - setPeople trims, de-duplicates ignoring case, and does nothing on deleted meetings.
  - Export tests prove byte-identical output without people (TXT, MD, JSON).
- T51 spec: covers every goal (link, auto title, attendees as people, speaker suggestions, reminder), non-goals, permission flow, data mapping onto T49, privacy (emails opt-in only), UI placement, testing, and 6 tasks (T56–T61). The EventKit claims are accurate: `NSCalendarsFullAccessUsageDescription`, `requestFullAccessToEvents`, entitlement `com.apple.security.personal-information.calendars`, and `calendarItemExternalIdentifier`. T56–T61 are well formed in the backlog, with deliverables, acceptance, dependencies and a fallback.
- T50 hands-on on the real library, on one meeting ("Test (Youtopia recording)") only:
  - Added "Ana Ruiz, Ben Okafor / ana ruiz / Cy Dunn". The chip showed "Ana Ruiz, Ben Okafor +1", so the case-insensitive duplicate was dropped.
  - The database JSON holds 3 manual people and contractVersion 1.
  - TXT, MD and JSON exports (written to scratch, then deleted) all show People. The JSON has meeting.people and no linkedEvent.
  - Cancel discards edits.
  - Cleared the box and saved: the people key is gone from the JSON, and the chip shows "Add people...".
  - The calendar chip ignores clicks, shows no popover, and its tooltip is correct.
  - Light appearance looks fine. The ⌘↩ shortcut saves.
  - The app was killed by PID. Appearance was toggled with the toolbar button (two clicks), and no appearance key was persisted in defaults.
- Regressions: sidebar, selection, tabs and the toolbar looked normal. I did not exercise search, rename or delete, which was out of scope.
