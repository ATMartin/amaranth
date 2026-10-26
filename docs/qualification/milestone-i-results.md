# Milestone I — transcript reading view and density: result notes (2026-10-26)

Tasks T35–T38, one commit each on main. Decisions for this run (user, 2026-10-26): include optional T37 (Columns stays
the default); T36 row gain measured read-only on "Build Carolina check-in" with counts only (real-content screenshots
stay out of git; committed screenshots use fixtures); stop after I is validated; hands-on checks left to the user.

## T35 Three-column transcript with speaker runs
- `TranscriptRows.runs(_:)` / `runStarts(_:)` (Presentation): consecutive speech rows with the same `assignment` and
  source form a run; every gap row is its own run; `.unknown` groups with `.unknown`, `.multiple` only with the same
  speaker list. Rows stay individually addressable (ids, `.tag`, context menu, play-from unchanged).
- Columns: time 60 pt · speaker 140 pt (initials disc + name on the first row of a run, middle-truncated with a tooltip)
  · text. Flags and the MIC/SYS badge moved to the trailing edge of the text line, so a row is one line taller only
  when its text wraps. Overlap rows show a group disc and drop the "(overlapping)" suffix in the column.
- Speaker colours: FNV-1a of the speaker id into 8 system colours (adapt to light/dark); unknown and overlap are grey.
- VoiceOver: each row's text is labelled "<speaker>: <text>", continuation rows included.
- Evidence jump fix (pre-existing bug found by the new check): one `scrollTo` on the two-hour meeting landed ~75 rows
  away (rows have estimated heights until laid out) and a pane opened with the focus already set selected nothing;
  HEAD before T35 failed both cases. The pane now selects and scrolls up to three times, 120 ms apart.
  `--self-test ui-render` checks both cases (`evidence-jump`, while-shown and on-appear): target row selected and
  inside the visible range (row 1801 of 3601: visible 1792–1810; row 1200: 1191–1209).
- Tests: `TranscriptRunsTests` (7). `--self-test ui-render`: pass; 3,601-row transcript renders in 0.21 s.
- Manual (user): scroll a long real meeting (checklist item 31). No 2-hour corpus meeting is in the library; the
  synthetic two-hour meeting is the automated stand-in.
