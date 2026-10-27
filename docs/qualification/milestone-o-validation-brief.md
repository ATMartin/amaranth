# Milestone O: brief for the independent validator

You are validating **Milestone O ("Calendar integration", T56–T61)** of Amaranth, a local macOS meeting recorder.

- **Repo:** `/Users/alex/sandbox/amaranth-v2`.
- **Spec (accepted, with the user's 3 decisions at the end):** `docs/decisions/0006-calendar-integration-spec.md`.
- **Backlog:** `docs/implementation-tasks.json` (T56–T61: deliverables, acceptance).
- **Commits (one per task):** `git log --oneline d48c5f5..HEAD` (T56 cc96656, T57 ad152a9, T58 8865ef7, T59 962d432, T60 a243d5e, T61 48ad775).
- **Implementation notes, incl. stated deviations:** `docs/decisions/calendar/0001-calendar-integration.md`.
- **Evidence:** `docs/qualification/evidence/2026-10-27/calendar-*` and `speaker-rename`; checklist items 52–58 in
  `docs/qualification/ui-manual-checklist.md`.

## User decisions (2026-10-27)
- At Record, an event is **never** linked or the meeting renamed without explicit approval, even with one match.
- Unlinking **keeps** calendar-sourced people. T61 (reminder) included as an experiment.
- Real calendars may be read (read-only); real event titles and attendee names must never be committed or quoted
  in your report (counts and "a meeting on <date>" are fine).
- No network, no cloud calendar APIs, never write to calendars, never start a recording automatically.

## Ground rules
- Be adversarial and independent; check claims against code, tests and evidence, or by running things.
- **Don't** modify source or docs. Scratch files only under `/private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/00af42e8-68f9-42c5-889a-8213547dd9ca/scratchpad/validator/`.
- **Don't** run `xcodegen`/`xcodebuild`: the Debug build in `build/DerivedData` is the final T61 code (calendar
  access for it was already granted by the user). Don't run perf-suite or `capture-*` self-tests. `rm` is aliased; use `/bin/rm -f`.
- You may run `swift test --scratch-path /private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/00af42e8-68f9-42c5-889a-8213547dd9ca/scratchpad/validator/build --filter "Calendar|SpeakerRename|MeetingPeople|MeetingStoreTests|DataLifecycle|RecorderPresentation|Contract"`,
  and `build/DerivedData/Build/Products/Debug/Amaranth.app/Contents/MacOS/Amaranth --self-test ui-render --self-test-output /private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/00af42e8-68f9-42c5-889a-8213547dd9ca/scratchpad/validator/png`
  (300 s timeout; must pass; look at calendar-*, header-linked*, event-prompt-*, recording-strip-calendar,
  main-recording-toolbar-*-calendar-*, settings-calendar*, speaker-rename-* in png/light and png/dark).
- The calendar self-test already ran: `{"before":"notDetermined","step":"status"} {"after":"fullAccess","presentation":"ready","prompted":"true","step":"request"} {"allDay":"0","attendees":"0","calendars":"3","cancelled":"0","events3Days":"0","mappedOK":"true","queryMs":"0","recurring":"0","rooms":"0","step":"read","unnamed":"0","withAttendees":"0"} {"result":"pass","test":"calendar-access"} `.
  You may re-run it: `open -W -n build/DerivedData/Build/Products/Debug/Amaranth.app --args --self-test calendar-access --self-test-output /private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/00af42e8-68f9-42c5-889a-8213547dd9ca/scratchpad/validator/cal.jsonl`.
- Real database read-only with `sqlite3 -readonly`; never print transcript/notes text.

## Hands-on (real app, real library — the Release app is not running)
Launch with `open -n build/DerivedData/Build/Products/Debug/Amaranth.app`; drive with osascript/System Events (Terminal
has Accessibility); capture with `screencapture -x`. Quit at the end with Amaranth ▸ Quit, or kill by PID from
`pgrep -f "Debug/Amaranth.app/Contents/MacOS/Amaranth$"`. Never kill by name.

**Allowed:** select meetings, switch tabs, open the header calendar chip and its picker, search in it; open Settings →
Calendar and look (don't change toggles except as below); open the people editor and the speaker Rename sheet and
**Cancel**. You MAY link **one** meeting to a real event (if any event exists on a meeting's date) and then **revert
completely**: Unlink, remove the people the link added via the people editor, and restore the original title if you
pressed Use Event Title. Record exactly what you changed and confirm the revert with `sqlite3 -readonly` (people and
linked_event_id back to their prior state).

**Never:** press Record; turn on the reminder (it needs a person to answer a notification prompt); press "Remove
Calendar Data from All Meetings"; rename speakers; delete or export; change notes.

A defaults backup is at `/private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/00af42e8-68f9-42c5-889a-8213547dd9ca/scratchpad/validator/defaults-before.plist`; don't restore it yourself — list any defaults you changed.

## What to judge
1. **T56** permission: Info.plist key + entitlement in the built app; prompt only on user action and never at launch or
   while recording (read every call site of `requestAccess`/`request(`); status mapping incl. writeOnly/restricted.
2. **T57** chip: every state; picker ordering/search; snapshot mapping per the spec table; Update / missing / also-linked;
   Use Event Title never automatic; JSON export carries the link; narrow header.
3. **T58** merge rules (rooms/resources/groups/unnamed skipped, current user first, manual untouched, re-link no
   duplicates), unlink keeps people, emails only with the setting and never exported, deletion-bytes tests.
4. **T59** matching table (9 vs 11 min, overlap, all-day, declined, recurring); **prove no code path links without an
   approval action**; typed/renamed titles never changed (incl. the new `upsertMeeting(keepingStoredTitle:)` — does it
   break anything else that relies on upsert changing the title?); ui-render toolbar check at 900/1100 with the prompt.
   Judge the documented deviation (compact button + popover instead of inline Link/Not this): acceptable or not?
5. **T60** suggestions produce the identical edit to typing; rendered with/without people.
6. **T61** reminder planning/removal tests, notification-permission only on toggle, click never records; Settings →
   Calendar contents; "Remove calendar data" and email forgetting leave no bytes.
7. **Privacy/non-goals:** no network calls, no calendar writes (grep for EKEventStore save/remove, URLSession), event
   notes/location/URLs never read into storage.
8. **Regressions:** header chips, people chip, recording strip without a prompt, exports of meetings without links
   byte-identical, ui-render overall.

Write your verdict to `/private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/00af42e8-68f9-42c5-889a-8213547dd9ca/scratchpad/validator/milestone-o-verdict.md`: PASS / PASS WITH FIXES / FAIL, must-fix list, should-fix list,
"Needs a person" list, exactly what you changed in the real library and how it was reverted, and what you checked.
Return the same summary.
