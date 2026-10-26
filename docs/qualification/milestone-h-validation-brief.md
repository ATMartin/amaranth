# Milestone H: brief for the independent validator

You are validating **Milestone H ("Recorder in the toolbar", T30–T34)** of Amaranth, a local macOS meeting recorder and
transcriber. Repo: `/Users/alex/sandbox/amaranth-v2`. Backlog with each task's deliverables, acceptance, fallback and
a `result` field: `docs/implementation-tasks.json`. Source of the tasks: `docs/decisions/0005-design-review-2026-10-23.md`
and `docs/design-review/2026-10-23/transcript.md`. Each task is its own commit: `git log --oneline d4cc7c1..HEAD`
(T30 7fa78de, T31 79f5055, T32 8731f22, T33 a21d557, T34 74f11ab, then the capture-evidence commit 36513aa).
Results and the old-panel → new-home mapping: `docs/qualification/milestone-h-results.md`. Hands-on checklist items
26–30 (plus edited items 2, 4, 15, 16): `docs/qualification/ui-manual-checklist.md`.

## User decisions (2026-10-25)
- T21 is on hold; all of T30–T34 done in one go, **one commit per task**.
- The capture self-test was run once at the end on the final build (results doc, "Capture self-test" section). It
  fails on a `source.startDelayed` gap only; the claim is that this is a macOS 27.0.1 change, not H. Judge that claim
  (capture code diff since 6ac994e, evidence files 2026-10-16 vs 2026-10-25) but **don't run capture self-tests**.
- The validator was meant to automate the hands-on recorder pass with UI scripting. **Accessibility is not granted to
  Terminal** (`osascript -e 'tell application "System Events" to get UI elements enabled'` → false), so clicks and
  keystrokes can't be scripted. Do what you can without them (below) and list precisely what still needs a person.
- Added beyond the task text: Resume after a sleep interruption is offered in the strip and menu bar (before, an
  interrupted recording had no Resume anywhere). Judge whether it's correct and safe.

## Ground rules
- Be adversarial and independent. Check claims against code, tests and evidence, or by running things. Report anything
  overstated, unsupported or contradicted.
- **Don't** modify source or docs; scratch files only under `/private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/d7beaad8-d11e-41a0-8e97-a4451fa36b2b/scratchpad/validator/`. Don't run `xcodegen` or
  `xcodebuild` (a rebuild re-triggers macOS permission prompts), the perf-suite, or any `capture-*` self-test. Don't
  touch `~/Library/Application Support/Amaranth/` beyond what launching the app does, and never press Record.
  Never quote content of `Tests/Data/Recordings/` or perf `outputs/` (private meetings).
- `rm` is aliased; use `/bin/rm -f`. Never quit Amaranth by name (`tell application "Amaranth" to quit`): kill the
  Debug app by PID only (`pgrep -f "Debug/Amaranth.app/Contents/MacOS/Amaranth$"`).
- You may run:
  - `swift test --scratch-path /private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/d7beaad8-d11e-41a0-8e97-a4451fa36b2b/scratchpad/validator/build` (optionally `--filter`); about 6 minutes in full. The new tests are
    RecordingDefaultsTests, RecorderPresentationTests, DetailTabRulesTests, RecordingScratchpadTests (Tests/UI).
    `stalledCallbacksRaiseFaultWithinTwoSeconds` and `incrementalThenStopGivesTheBatchTranscript` have been flaky
    under load before; rerun alone before calling them failures.
  - The UI render self-test on the built Debug app (no permissions; the build is the final H code):
    `build/DerivedData/Build/Products/Debug/Amaranth.app/Contents/MacOS/Amaranth --self-test ui-render --self-test-output /private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/d7beaad8-d11e-41a0-8e97-a4451fa36b2b/scratchpad/validator/png`
    (run with a 300 s timeout), then look at the PNGs: record-control, record-options, recording-strip (all states +
    disk), recorder-banner, settings-recording, live-scratchpad-closed/open, recording-health, sidebar, main-*.
  - A real-window look: `open -n build/DerivedData/Build/Products/Debug/Amaranth.app`, wait ~5 s, get its PID as above,
    window id with `/private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/d7beaad8-d11e-41a0-8e97-a4451fa36b2b/scratchpad/winid <pid>`, capture with `screencapture -x -o -l<wid> <file>.png`, then kill by PID. Check the
    toolbar layout (● Record, ▾, Models at the leading edge, not truncated), the sidebar has no recorder, and **no
    popover is open at launch** (one earlier launch showed the Record options popover open by itself; it did not
    reproduce). Launch at least 3 times for that check.

## What to check
1. **Per task**: each deliverable and acceptance criterion in `implementation-tasks.json` is met in code, or its
   deviation is recorded. Pay attention to:
   - T30: one source of truth for defaults (`Presentation/RecordingDefaults.swift`); the recorder no longer writes
     UserDefaults; per-meeting popover choices don't leak into the next recording (`customized`, `loadDefaults` in
     `App/Recorder/RecorderModel.swift`); missing mic → System default plus notice; Settings change picked up when
     not customized.
   - T31: sidebar is meetings only; toolbar Record is one click with defaults; ⌘⇧R/⌘⇧P/⌘⇧S each registered once
     (grep `keyboardShortcut` in App/, include MenuBarContent and commands); consent sentence still shown before
     first Record (tooltip + onboarding); strip covers every RecorderState; banner messages dismissable; Quit while
     recording still asks; menu bar still works.
   - T32: `DetailTabRules` and `NotesArrivalSwitch` match the spec (transcript while recording, notes when they
     exist, one switch to Notes after Stop unless the user picked a tab); `LibraryModel` applies the rule once per
     opened meeting and doesn't fight the user (didSet guarded by `applyingTabRule`). Look for a race: notes arriving
     before `recordingStopped`, selection changes during recording, menu-bar start.
   - T33: Scratchpad hidden by default, ⌘⇧N, inline (not a sheet), auto-focus only when empty, text saved as a revision
     and kept after Stop; `includeInSummary` preserved.
   - T34: every item of the old sidebar recorder has a new home (mapping table in the results doc vs. the deleted
     RecorderPanel in `git show d4cc7c1:App/Recorder/QuickRecorderView.swift`).
2. **Regressions**: capture, storage, export, notes, model setup unchanged (`git diff d4cc7c1..HEAD --stat`). Full test
   suite passes. `scripts/check.sh` is what the author ran; you don't need to run it (it rebuilds).
3. **Docs**: task status/result fields, results doc and checklist match the code. Checklist items 26–30 are correctly
   scoped to what needs a person, given that UI scripting was unavailable.

## Output
Write your verdict to `/private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/d7beaad8-d11e-41a0-8e97-a4451fa36b2b/scratchpad/validator/milestone-h-verdict.md`: PASS or FAIL on the first line, then findings by
severity (blocking / should fix / note) with file:line or command evidence, then a section "Needs a person" listing
the hands-on checks you could not automate.
