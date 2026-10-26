# Milestone I — transcript reading view and density: result notes (2026-10-26)

Tasks T35–T38, one commit each on main. Decisions for this run (user, 2026-10-26): include optional T37 (Columns stays
the default); T36 row gain measured read-only on "Build Carolina check-in" with counts only (real-content screenshots
stay out of git; committed screenshots use fixtures); stop after I is validated; hands-on checks left to the user.

## T35 Three-column transcript with speaker runs
- `TranscriptRows.runs(_:)` / `runStarts(_:)` (Presentation): consecutive speech rows with the same `assignment` and
  source form a run; every gap row is its own run; `.unknown` groups with `.unknown`, `.multiple` only with the same
  set of speakers, order ignored (fixed after validation; it compared ordered lists before). Rows stay individually addressable (ids, `.tag`, context menu, play-from unchanged).
- Columns: time 60 pt · speaker 140 pt (initials disc + name on the first row of a run, middle-truncated with a tooltip)
  · text. Flags and the MIC/SYS badge moved to the trailing edge of the text line, so a row is one line taller only
  when its text wraps. Overlap rows show a group disc and drop the "(overlapping)" suffix in the column.
- Speaker colours: FNV-1a of the speaker id into 8 system colours (adapt to light/dark); unknown and overlap are grey.
- VoiceOver: each row's text is labelled "<speaker>: <text>", continuation rows included.
- Evidence jump fix (pre-existing bug found by the new check): one `scrollTo` on the two-hour meeting landed ~75 rows
  away (rows have estimated heights until laid out) and a pane opened with the focus already set selected nothing;
  HEAD before T35 failed both cases. The pane now selects and scrolls up to three times, 120 ms apart,
  in a `.task(id:)` cancelled by a newer focus or when the pane closes; it stops early if the user selects another row
  (a user scroll inside those ~240 ms can still be overridden).
  `--self-test ui-render` checks both cases (`evidence-jump`, while-shown and on-appear): target row selected and
  inside the visible range (row 1801 of 3601: visible 1792–1810; row 1200: 1191–1209).
- Tests: `TranscriptRunsTests` (7). `--self-test ui-render`: pass; 3,601-row transcript renders in 0.21 s.
- Manual (user): scroll a long real meeting (checklist item 31). No 2-hour corpus meeting is in the library; the
  synthetic two-hour meeting is the automated stand-in.

## T36 Compact type scale and text size
- `AppStyle` (App/Shared/AppStyle.swift): roles title 17 bold, section 14 semibold, headline/body 12, callout 11.5,
  caption 11, caption2 10; spacing 4/8/16. `.appFont(role)` multiplies by `\.textScale`. Used in the sidebar cards and
  search hits, meeting header, transcript (rows, gaps, badges, speaker/playback strip), notes (all text and editors)
  and the live transcript lines. Recording tab, export and the models sheet untouched. AppKit controls (segmented tab
  picker, speaker menus, buttons) keep their system size (the fallback's "content only" scope, applied from the start).
- Settings → Appearance (new tab, shared later with T43/T44): Text size Smaller / Default / Larger = ×0.9 / ×1 / ×1.2,
  `@AppStorage("textSize")` (`TextSize` in Presentation, `TextSizeTests`), applied at the window root.
- Transcript density: no row separators, 0–1 pt row insets with 3 pt above each new speaker run, and the playback
  control and speaker menus share one strip.
- Row count (`--self-test ui-density`, main window 1280×826, Transcript tab, Details off, fully visible rows):

  | Build | Build Carolina check-in (49 min, user library, read-only copy) | Synthetic two-hour meeting |
  |---|---|---|
  | before Milestone I (ee8de37) | 15 | — |
  | before T36 (T35, 4bc9acd) | 21 (18 speech) | 17 |
  | T36 Smaller | 33 (30) | 25 (validator: 26 after T37/T38) |
  | **T36 Default** | **29 (26): +38% vs before T36** (speech +44%; +93% vs before I) | **23: +35%** |
  | T36 Larger | 24 (21) | 20 |

  Real-meeting screenshots stay in `Tests/Data/Recordings/ui-density/` (gitignored); `scripts/ui-density.sh` copies
  the database with sqlite `.backup` into a temp directory, so the app never opens the library.
- Committed screenshots (fixtures, 1280×826, sidebar included): `docs/qualification/evidence/2026-10-26/t36/`
  (`before-*` from the T35 build; `after-{smaller,default,larger}-*`). No clipped or truncated controls at any size.
- `--self-test ui-render --text-size {smaller,default,larger}`: pass at each size (evidence jump passes too).
- Capture note: offscreen captures without an explicit window background come out with a transparent (black-looking)
  header; the density test paints the window background like ui-render does.
- Full `swift test`: all pass except the known load flake `incrementalThenStopGivesTheBatchTranscript` (failed once,
  passed in the run before; ASR untouched).
- Manual (user): checklist item 32.

## T37 Conversation bubbles (exploration)
- Settings → Appearance → Transcript style: Columns (default) / Bubbles (`TranscriptStyle`, `@AppStorage("transcriptStyle")`,
  applied at the window root with the text size). Recommendation and evaluation: `docs/decisions/ui/0002-transcript-bubbles.md`
  (keep Columns; Bubbles fits half as many rows and the left/right split carries no information with 3+ remote speakers).
- Both styles share rows, ids, context menu and selection: play-from (time caption), correct text, reassign, mark
  uncertain, evidence jump (ui-render `evidence-jump` passes for `columns` and `bubbles`), skim/Details.
- Also changes T35 colours: per-meeting distinct speaker colours (`TranscriptRows.paletteIndices`, tested), and cyan
  instead of blue in the palette (blue is the accent / your bubbles).
- `ui-density` takes `--transcript-style` and `--details`; its preferences live in a throwaway defaults suite.
- Manual (user): checklist item 33.

## T38 Speaker actions from the speaker column
- The disc and name (first row of a run, both styles) are a borderless menu: **Rename…** and **Merge Into ▸** for the
  row's speaker (one submenu per speaker on overlap rows; unknown rows have none), then **Assign This Line To ▸** (same
  items as the row's context menu). Plain text while the transcript is provisional.
- Both menus and the SpeakerBar call the same `rename` / `merge` functions on `EditComposer`; `SpeakerMenu`
  (Presentation) chooses the subjects, merge targets and assign targets, and the shared functions make the edits identical by
  construction (`SpeakerMenuTests` covers the menu contents; its edit-equality check only restates that). The row and column "assign" lists now leave out the row's current speaker (a no-op), and
  "Unknown Speaker" is not offered for a line that is already unknown.
- SpeakerBar shows only with Details on (skim mode: playback control alone in the strip).
- Not automatable here: offscreen SwiftUI menus have no AppKit view or accessibility element until clicked, and the
  terminal has no Accessibility permission. Menu contents and clicks: checklist item 34.
- `--self-test ui-render` passes at all three text sizes; package UI tests 49/49.

## Validation (2026-10-26)
Sonnet validator: **PASS**, no blocking findings (`docs/qualification/milestone-i-verdict-v1.md`). Should-fix items
fixed: overlap runs compare speaker sets; the evidence-jump retry runs in a cancellable `.task(id:)` and yields to a
user selection; the results doc no longer overstates the edit-equality test. After the fixes: `ui-render` passes at
all three sizes (evidence jump ok in both styles), UI tests 49/49. Remaining notes (live header fonts, `onboarded`
written by ui-render since Milestone C) are recorded in the verdict. Hands-on: checklist items 31–34.
