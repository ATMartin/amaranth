# Milestone M: brief for the independent validator

You are validating **Milestone M ("Calendar and people placeholders", T49–T51)** of Amaranth, a local macOS meeting
recorder and transcriber. Repo: `/Users/alex/sandbox/amaranth-v2`. Backlog with each task's deliverables, acceptance
and fallback: `docs/implementation-tasks.json` (ids T49, T50, T51; also the new T56–T61 / milestone "O").
Source: `docs/decisions/0005-design-review-2026-10-23.md` and `docs/design-review/2026-10-23/transcript.md`
(10:24–11:15), reference image `docs/design-review/2026-10-23/granola-note-header-calendar-people.png`.
One commit per task: `git log --oneline 3b337a9..HEAD` (T49 7b6ef1a, T51 78c09a0, T50 44db3b5). Spec:
`docs/decisions/0006-calendar-integration-spec.md`. Evidence: `docs/qualification/evidence/2026-10-26/header-chips/`.
Hands-on checklist: `docs/qualification/ui-manual-checklist.md` (new items 41–43).

## User decisions (2026-10-26)
- All of M, one commit per task, order T49 → T51 → T50, hands-off; stop after M.
- **Exports do change for this one case** (overrides the design review's "export unchanged"): people appear in
  TXT/MD ("People: …" under the title) and in the JSON meeting, only when present. Exports of meetings without people
  must be byte-identical to before.
- T51's acceptance says "tasks added only after the user's review"; the user chose to have them added **now** as
  Milestone O marked pending review. Don't flag that as a deviation; do judge the spec's quality.
- Contract rule: `ContractVersion.current` must stay 1 (additive, defaulted fields); a SQLite migration only.
- Hands-on: the user allows the Debug app on their **real library**, and you may **add people to one meeting and
  then remove them** (rules below). The library and settings were backed up beforehand.

## Ground rules
- Be adversarial and independent. Check claims against code, tests and evidence, or by running things.
- **Don't** modify source or docs; scratch files only under `/private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/906028d3-6275-4d58-9311-d0732b725d52/scratchpad/validator/`. Don't run `xcodegen` or `xcodebuild` (the
  Debug build in `build/DerivedData` is the final T50 code), the perf-suite, or any `capture-*` self-test.
- `rm` is aliased; use `/bin/rm -f`.
- You may run `swift test --scratch-path /private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/906028d3-6275-4d58-9311-d0732b725d52/scratchpad/validator/build --filter "MeetingStoreTests|ExportTests|MeetingPeopleTests|ContractRoundTrip"`
  and the render self-test (exec the binary directly, 300 s timeout):
  `build/DerivedData/Build/Products/Debug/Amaranth.app/Contents/MacOS/Amaranth --self-test ui-render --self-test-output /private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/906028d3-6275-4d58-9311-d0732b725d52/scratchpad/validator/png`
  → `png/light/` and `png/dark/`; the result must be pass. Look at `main-*.png`, `people-editor*.png`.
- You may read the real database **read-only** with `sqlite3 -readonly` (schema, `PRAGMA user_version`, the
  `people` / `linkedEvent` keys of the meeting JSON). Don't print transcript or notes text.

## Hands-on (real app)
Launch: `open -n build/DerivedData/Build/Products/Debug/Amaranth.app` (this migrates the real library to schema v3;
expected). Drive it with `osascript` / System Events (Terminal has Accessibility) and capture with
`screencapture -x` or `screencapture -l <windowid>`. Quit it at the end (Amaranth ▸ Quit, or kill by PID from
`pgrep -f "Debug/Amaranth.app/Contents/MacOS/Amaranth$"`; never by name).
- **Allowed writes, on exactly one meeting** ("Test (Youtopia recording)"): open the people chip, add names, Save,
  edit, Cancel, and finally clear the box and Save so the meeting ends with **no people**. You may Export that one
  meeting (Markdown, Plain Text, JSON) **into `/private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/906028d3-6275-4d58-9311-d0732b725d52/scratchpad/validator/`** only, to check the People line, then delete those export files.
- **Never**: press Record (or ⌘⇧R), rename, merge or assign speakers, Correct Text, edit Your notes or the scratchpad,
  Regenerate/Generate notes, Retry/Process, Delete anything, or install/remove models. No people on the other meetings.
- Allowed look-only: select meetings, switch tabs, ⌘D, hover for tooltips, Tab through the header (the calendar chip
  must not take focus or clicks), toggle appearance (put it back to Match system when done).
- Privacy: **never quote transcript or notes text** in your report (meeting titles are fine); real-content
  screenshots stay in `/private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/906028d3-6275-4d58-9311-d0732b725d52/scratchpad/validator/`.

Check checklist items 41–42 in both Light and Dark. Item 43 needs recording: put it under "Needs a person", along with
anything else you can't automate (VoiceOver).

## What to judge
1. T49: domain shape matches the deliverable (Person name/source manual|calendar; LinkedEvent identifier, title,
   start, end, calendarName, source); contract version unchanged; old rows decode (test + the real v2 library after
   migration); migration is correct and idempotent; setters; does `upsertMeeting` keeping stored metadata break any
   writer that legitimately sets people (e.g. first insert)? Any path that can still drop people (recorder copy,
   recovery, rename, notes/processing record writes, deletion)? Exports with and without metadata covered by tests,
   byte-identical without.
2. T51: spec covers every item in the deliverable (goals incl. auto title, attendees as people and as speaker-rename
   suggestions, reminder; permission flow incl. usage description and denied state; data mapping onto T49; privacy incl.
   emails never stored unless opt-in; UI placement; 4–6 tasks) and the explicit non-goals; technical accuracy of the
   EventKit claims (full-access API and Info.plist key on macOS 14+, entitlement under hardened runtime, identifiers);
   tasks T56–T61 well-formed in the backlog.
3. T50: chips as specified (calendar date not editable, person.2 "Add people…" popover editor comma/line, link chip
   disabled with tooltip "Calendar linking is planned"), T27 glyph and duration kept, clearly inert placeholder, both
   appearances, text sizes; adding people persists and shows in exports; ui-render passes.
4. Regressions elsewhere (header layout at narrow widths, sidebar, search, rename, deletion).

Write your verdict to `/private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/906028d3-6275-4d58-9311-d0732b725d52/scratchpad/validator/milestone-m-verdict.md`: PASS / PASS WITH FIXES / FAIL, a must-fix list, a should-fix list,
a "Needs a person" list, and what you checked. Return the same summary.
