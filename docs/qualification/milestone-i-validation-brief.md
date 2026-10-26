# Milestone I: brief for the independent validator

You are validating **Milestone I ("Transcript reading view and density", T35–T38)** of Amaranth, a local macOS meeting
recorder and transcriber. Repo: `/Users/alex/sandbox/amaranth-v2`. Backlog with each task's deliverables, acceptance
and fallback: `docs/implementation-tasks.json`. Source of the tasks: `docs/decisions/0005-design-review-2026-10-23.md`
and `docs/design-review/2026-10-23/transcript.md`. Each task is its own commit: `git log --oneline ee8de37..HEAD`
(T35 4bc9acd, T36 0aad162, T37 035899d, T38 f015c67). Results: `docs/qualification/milestone-i-results.md`.
T37 decision note: `docs/decisions/ui/0002-transcript-bubbles.md`. Hands-on checklist items 31–34:
`docs/qualification/ui-manual-checklist.md`.

## User decisions (2026-10-26)
- All of T35–T38 in one go, including optional T37; **one commit per task**; Columns stays the default style.
- T36's row-count acceptance is measured on the user's real meeting "Build Carolina check-in", **read-only**, reporting
  counts only; screenshots of real meetings stay in the gitignored `Tests/Data/Recordings/ui-density/`; committed
  screenshots use fixtures (`docs/qualification/evidence/2026-10-26/t36/`, `t37/`).
- Hands-on checks (clicking menus, scrolling feel, VoiceOver) are left to the user. Terminal has no Accessibility
  permission, so no UI scripting.
- Changes beyond the task text, judge them: an evidence-jump fix in T35 (scroll landed ~75 rows off on long meetings
  before; now selects and scrolls up to 3 times); in T37 per-meeting distinct speaker colours and no blue in the
  palette; in T38 the assign lists drop the row's current speaker and "Unknown Speaker" for already-unknown lines.

## Ground rules
- Be adversarial and independent. Check claims against code, tests and evidence, or by running things. Report anything
  overstated, unsupported or contradicted.
- **Don't** modify source or docs; scratch files only under `/private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/1d02d2f7-c16b-44b2-9e5e-9b10b6b5cd76/scratchpad/validator/`. Don't run `xcodegen` or `xcodebuild` (the Debug
  build in `build/DerivedData` is the final T38 code), the perf-suite, or any `capture-*` self-test. Never press
  Record. Don't write to `~/Library/Application Support/Amaranth/`. Never quote content of
  `Tests/Data/Recordings/` (private meetings), including text visible in its screenshots; meeting titles are fine.
- `rm` is aliased; use `/bin/rm -f`. If you launch the app, kill it by PID only
  (`pgrep -f "Debug/Amaranth.app/Contents/MacOS/Amaranth$"`), never by name.
- You may run:
  - `swift test --scratch-path /private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/1d02d2f7-c16b-44b2-9e5e-9b10b6b5cd76/scratchpad/validator/build` (optionally `--filter`); about 6 minutes in full. New tests:
    TranscriptRunsTests, TextSizeTests, SpeakerMenuTests (Tests/UI). `stalledCallbacksRaiseFaultWithinTwoSeconds`
    and `incrementalThenStopGivesTheBatchTranscript` are known load flakes; rerun alone before calling them failures.
  - UI render self-test (no permissions, exec the binary directly; 300 s timeout), at each text size:
    `build/DerivedData/Build/Products/Debug/Amaranth.app/Contents/MacOS/Amaranth --self-test ui-render --text-size {smaller,default,larger} --self-test-output /private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/1d02d2f7-c16b-44b2-9e5e-9b10b6b5cd76/scratchpad/validator/png-<size>`.
    Its `evidence-jump` lines must be ok for both styles. Look at the PNGs: transcript-*, transcript-details-*,
    transcript-bubbles-*, transcript-evidence-jump, main-*, notes-*, sidebar.
  - Density self-test on fixtures:
    `…/Amaranth --self-test ui-density --meeting ui-long --png-dir /private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/1d02d2f7-c16b-44b2-9e5e-9b10b6b5cd76/scratchpad/validator/density --label x [--text-size …] [--transcript-style bubbles]`.
  - The real-meeting row count: `scripts/ui-density.sh "Build Carolina check-in" <label> [smaller|default|larger]`
    (copies the database with sqlite `.backup` to a temp dir; read the script first to confirm it never writes the
    library). PNGs land in the gitignored folder; you may look at them for layout but don't quote their text.
  - The "before" baselines (T35 build: 21 rows; pre-milestone: 15) were measured from builds at 4bc9acd and ee8de37 that
    you can't rebuild; judge whether the method is sound and the T36 claim (Default 29 rows, ≥ 30% more) holds.

## What to check
1. **Per task**: each deliverable and acceptance criterion is met in code, or its deviation is recorded. In particular:
   - T35: `TranscriptRows.runs` semantics (gaps and source changes break runs; unknown groups; overlap with the same
     set only); rows stay individually addressable (id/tag/context menu/play); fixed column widths; VoiceOver label on
     continuation rows; evidence jump correctness (`App/Transcript/TranscriptPane.swift` onChange; check the retry
     loop can't fight a user scroll or a newer focus).
   - T36: tokens actually used for sidebar, header, transcript, notes; setting persisted under `textSize` and applied
     at the window root; nothing clipped at 1280 px for all sizes; scope respected (Recording tab, export, models
     sheet unchanged: `git diff ee8de37..HEAD --stat`).
   - T37: both styles support play-from, correct text, reassign, evidence jump, skim/Details (code paths shared?);
     default unchanged; decision note's evaluation matches the evidence.
   - T38: column menu = SpeakerBar's Rename…/Merge Into + Assign This Line To; same `UserEdit`s; bar only with Details
     on; provisional transcripts have no menu.
2. **Regressions**: capture, storage, ASR, notes, export unchanged; full test suite passes; self-tests don't touch the
   user's preferences or library (look at `App/Launch/UIDensitySelfTest.swift` and `UIRenderSelfTest.swift`).
3. **Docs**: task status fields, results doc and checklist items 31–34 match the code and are scoped to what needs a
   person.

## Output
Write your verdict to `/private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/1d02d2f7-c16b-44b2-9e5e-9b10b6b5cd76/scratchpad/validator/milestone-i-verdict.md`: PASS or FAIL on the first line, then findings by severity (blocking /
should fix / note) with file:line or command evidence, then a section "Needs a person" listing the hands-on checks
you could not automate.
