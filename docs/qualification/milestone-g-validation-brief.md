# Milestone G: brief for the independent validator

You are validating **Milestone G ("Design-review quick wins", T22–T29)** of Amaranth, a local macOS meeting recorder
and transcriber. Repo: `/Users/alex/sandbox/amaranth-v2`. Backlog with each task's deliverables, acceptance, fallback
and a `result` field: `docs/implementation-tasks.json`. Source of the tasks: the user's design review,
`docs/design-review/2026-10-23/transcript.md` and `docs/decisions/0005-design-review-2026-10-23.md`.
Each task is its own commit: `git log --oneline 2ccfa73..HEAD` (T22 2ce6fd0 … T29 ce08545).

## User decisions that override the task text (2026-10-23)
- All eight tasks done in one go; **one commit per task** (instead of one per milestone).
- T22: each note keeps a right-click **Show in Transcript** in both modes (not in the original spec).
- T23: **topics removed entirely** (the user rejected keeping them as a hidden intermediate step twice, including after
  seeing that the overview came out empty), then "fix the overview" — see notes/0002, 2026-10-23 section.
- T23: the 60-minute corpus notes timing was **not run** (user decision); shorter meetings and the notes checks were.
  Runs over 60 minutes are never run (so the 120-minute planted notes item is not run).
- Hands-on UI checks (clicking, focus rings, cursor, hover tooltips, keyboard shortcuts, relaunch persistence) are
  **left to the user**: checklist items 19–25 in `docs/qualification/ui-manual-checklist.md`. Judge whether they are
  correctly scoped and whether automatable parts were automated, not whether a person ran them.

## Ground rules
- Be adversarial and independent. Check claims against code, tests and evidence, or by running things. Report anything
  overstated, unsupported or contradicted.
- **Don't** modify source or docs; scratch files under `/tmp` only. Don't run `xcodegen` or `xcodebuild`, the
  perf-suite, or audio-capture self-tests. Don't touch `~/Library/Application Support/Amaranth/`. Never quote content of
  `Tests/Data/Recordings/` or of perf `outputs/` directories (private meetings); counts and metrics are fine.
- You may run:
  - `swift test --scratch-path /tmp/amaranth-validate-g` (optionally `--filter`); about 6 minutes in full.
    `incrementalThenStopGivesTheBatchTranscript` (real ASR model) failed once under full-suite load during this
    milestone and passed twice alone; judge whether that matters for G.
  - The UI render self-test on the built Debug app (no permissions):
    `open -W -n --stdout /tmp/g-out.txt --stderr /tmp/g-err.txt build/DerivedData/Build/Products/Debug/Amaranth.app --args --self-test ui-render --self-test-output /tmp/g-png`
    then look at the PNGs (notes-*, notes-details-*, notes-expanded-*, transcript-*, transcript-details-*, main-*,
    sidebar.png). The "reentrant NSTableView" AppKit warning is pre-existing tracked item 19.

## What to check
1. **Per task**: each deliverable and acceptance criterion in `implementation-tasks.json` is met in code, or its
   deviation is a recorded user decision or the task's own fallback. Pay attention to:
   - T22: one persisted key (`reviewShowDetails`, default off, pinned by a test); ⌘D registered exactly once; the
     uncertain marker always visible; exports untouched.
   - T23: no topics in prompt/grammar/UI/new revisions; old revisions still export topics; `notes-v3` bump does not
     mark existing notes stale (read `Storage/Notes/NotesRecords.swift` and the scheduler); notes checks
     (evidence 100%, planted, injection 10/10, uncertain share within +5 points) in
     `docs/qualification/milestone-g-t23-notes.md` and `Benchmarks/Results/2026-10-23-perf-t23d/report.md`. Look hard
     at the new overview path (`NotesPipeline.makeOverview`): can raw transcript lines still inject a claim, a decision,
     a name or a number into the overview? Are the four iterations reported honestly?
   - T24: collapse state persisted per editor; collapsing flushes the debounced save; tests for flush-within-window.
   - T25: speech-row identity unchanged in skim mode (evidence jumps); every gap still represented (VoiceOver label);
     tests.
   - T26: header not editable; rename in the sidebar context menu; empty title keeps the old one; search updated.
   - T27: every `MeetingStatus` combination maps to one glyph + tooltip; test enumerates them; cards ≤ 3 lines;
     "under half the previous height" claim (153 → 77 px per card in ui-render).
   - T28: field audit complete (grep `App/` for TextField/TextEditor/searchable); no `.plain` field without a focus
     indicator; the insertion-point fallback is recorded.
   - T29: shortcuts registered once; menu actions blocked while a sheet is open; tooltip coverage; tester guide table.
2. **Regressions**: Recording tab, export formats and the model sheet were out of scope and must be unchanged
   (diff `2ccfa73..HEAD` on those files). Full test suite passes.
3. **Docs**: task `status`/`result` fields, the notes decision record and the checklist match the code.

## Output
Write your verdict to `/tmp/milestone-g-verdict.md`: PASS or FAIL, then findings ordered by severity (blocking /
should fix / note), each with file:line or command evidence.
