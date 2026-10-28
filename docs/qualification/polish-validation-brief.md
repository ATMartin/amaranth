# Polish group (T74–T81): brief for the independent validator

You are validating the **Polish group (T74–T81)** of Amaranth, a local macOS meeting recorder: visual feedback on the
Inner Circle / Forest redesign from the user's 2026-10-28 screencast.

- **Repo:** `/Users/alex/sandbox/amaranth-v2`.
- **Backlog:** `docs/implementation-tasks.json` (T74–T82: context, deliverables, acceptance).
- **Commits (one per task):** `git log 192ffa3..HEAD` (T74 9267849, T75 8052c2e, T76 6ab0210, T77 c5b28e1, T78 78c1a4f,
  T79 7b52da3, T80 a20732b, T81 80cde3e). Each commit message lists what changed and any deviation.
- **Design:** `docs/decisions/ui/0004-inner-circle-identity.md` (T74 section on the dark accent below AA),
  `docs/design-handoff/Preview/index.html` (the handoff's `.am-record` button for T76).

## User decisions (2026-10-28)
- T74: dark accent `#C25A7C`, **below AA on purpose** (an experiment). Don't fail it for being below 4.5:1; do check
  the exception is documented, tested at its stated floors, and limited to the accent's dark pairs.
- T77: cards and toolbar lose the models button; the sidebar footer warns ("No local model found") and opens Settings
  on the Models tab.
- T79: Export in the shared menu works on **any** card (loads that meeting on demand), disabled only without a transcript.
- T80: cards show only a processing spinner and a failed-processing mark.
- Hands-on checks in the real app are left to the user (the user's Release app is running against the real library;
  don't launch a second instance of either build).

## Ground rules
- Be adversarial and independent; check claims against code, tests and renders.
- `<scratch>` below is `/private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/9c59fd95-37c1-423f-a21d-07792f676481/scratchpad`.
- **Don't** modify source or docs. Scratch files only under `<scratch>/validator/`.
- **Don't** run `xcodegen`/`xcodebuild`, `scripts/check.sh` or `scripts/stop-layout.sh`; don't `open` the app.
  `rm` is aliased; use `/bin/rm -f`.
- You may run `swift test --scratch-path <scratch>/validator/build --filter "Palette|MeetingStatusGlyph|LibraryAndAudioDetails|MeetingTitle|MeetingPeople"`
  and the headless render:
  `timeout 300 build/DerivedData/Build/Products/Debug/Amaranth.app/Contents/MacOS/Amaranth --self-test ui-render --self-test-output <scratch>/validator/png`
  (it uses a temporary store, never the user's library; must end with `{"result":"pass"}`). Offscreen renders leave
  the split view's sidebar and inspector blank in `main-*.png`; use `sidebar.png`, `ask-pane-*.png`,
  `main-toolbar.png` and `main-recording-toolbar-*.png` (those are on-screen windows) for those areas.
- Evidence already gathered (read, don't re-run): `<scratch>/check82.log` (scripts/check.sh), `<scratch>/stop82/`
  (scripts/stop-layout.sh, 8 variants with window captures; look at `w900/stop-layout-4-notes.png` and
  `w900-sidebar-closed/stop-layout-1-recording.png`).

## What to judge
1. **T74** catalog ↔ AppPalette match; `accentBelowAA` floors vs. measured ratios; light still AA; every place the
   accent is used as text on Selection is covered by the 2.5:1 exception (or flag it).
2. **T75** no window title, no shared glass capsules, Canvas title bar (`canvasTitleBar()`), smaller sun/moon, list-icon
   sidebar toggle that stays in sync with View ▸ Hide Sidebar / ⌃⌘S and with the probe's `toggleSidebar:`; no item
   lands in the toolbar overflow at 900/1100 pt (ui-render `toolbar-recording` steps).
3. **T76** Record button vs. the handoff (`.am-record`); ⌘⇧R, help and VoiceOver labels intact.
4. **T77** model sheet and toolbar button gone with no dead references; Settings tab selection persists and
   `openSettings(.models)` / `(.recording)` work; footer states incl. `.checking` (no flash) and `.installing`.
5. **T78** × and Esc clear query, hits and panel and refocus; Esc when no results but text typed; opening a match still
   keeps results.
6. **T79** both menus are the same `MeetingActionsMenu`; Export on a closed meeting loads the right meeting; rename and
   delete confirmations work from header, card and the Audio details tab (MainView-level presentation), including with
   the sidebar collapsed; playback stops before deleting the open meeting; **⌘D registered exactly once** (judge the
   stated deviation: the ⋯ menu's Show Details has no ⌘D glyph); ⌘E still works; header fits at 900 pt with both panes.
7. **T80** `cardGlyph` truth table vs. the decision; header still shows the full glyph; card density and 180 pt ideal.
8. **T81** copy changes exactly as specified.
9. Regressions: anything else these commits broke (VoiceOver labels, keyboard navigation in the sidebar list,
   focus, dark/light parity, sheets or dialogs presented twice, state leaks in `LibraryModel.actionRequest`).

## Report
Write your verdict to `<scratch>/validator/verdict.md`: **PASS**, **PASS WITH FIXES** or **FAIL**, then numbered
**must-fix** (acceptance not met or a real bug) and **should-fix** items, each with file:line and evidence, then a
list of hands-on checks you recommend the user do. Keep real meeting content out of the report.
