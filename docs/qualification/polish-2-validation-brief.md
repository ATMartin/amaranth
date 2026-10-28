# Polish 2 (T83–T87): brief for the independent validator

You are validating **Polish 2 (T83–T87)** of Amaranth, a local macOS meeting recorder: UI feedback from the user after a
few meetings on the restyled build (2026-10-28).

- **Repo:** `/Users/alex/sandbox/amaranth-v2`.
- **Backlog:** `docs/implementation-tasks.json` (T83–T88: context with the user's words, deliverables, acceptance).
- **Commits (one per task):** `git log 6e99e5e..HEAD` (T83 5f1167c, T84 fb5ecdd, T85 ce1af35, T86 9984e39, T87 776d749).
  Each commit message lists what changed and any deviation.

## User decisions (2026-10-28)
- T83: no "Unsorted" scope in Ask unless asked; with Unsorted shown, Ask offers Meeting | All.
- T85: "fade a little more" = the current colour at about 0.8 opacity (lighter than today), ≈ 9 pt.
- T86: Ask toggle icon is the SF Symbol `bubble.left` (user's pick).
- Hands-on checks in the real app are left to the user (the user's Release app is running against the real library;
  don't launch a second instance of either build).

## Ground rules
- Be adversarial and independent; check claims against code, tests and renders.
- `<scratch>` below is `/private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/80a3b65c-4db9-40a7-8c60-a964e0509d65/scratchpad`.
- **Don't** modify source or docs. Scratch files only under `<scratch>/validator/`.
- **Don't** run `xcodegen`/`xcodebuild`, `scripts/check.sh` or `scripts/stop-layout.sh`; don't `open` the app.
  `rm` is aliased; use `/bin/rm -f`.
- You may run `swift test --scratch-path <scratch>/validator/build --filter "LibraryFolders|AskAnything"` and the headless render:
  `timeout 400 build/DerivedData/Build/Products/Debug/Amaranth.app/Contents/MacOS/Amaranth --self-test ui-render --self-test-output <scratch>/validator/png`
  (temporary store, never the user's library; must end with `{"result":"pass"}`). Offscreen renders leave the split
  view's sidebar and inspector blank in `main-*.png`. **Toolbar positions:** ui-render's `main-toolbar.png` and
  `main-recording-toolbar-*.png` come from a hosted window that doesn't split the toolbar into columns, so they show
  item order only; real positions are in the stop-layout captures below.
- Evidence already gathered (read, don't re-run): `<scratch>/check88.log` (scripts/check.sh at HEAD),
  `<scratch>/stop87/` (scripts/stop-layout.sh at T87, 8 variants; each `out.jsonl` has `toolbar-corner`,
  `toolbar-corner-ask-closed` and `toolbar-corner-recording` steps with measured x ranges; captures
  `stop-layout-0a-ask-closed.png`, `stop-layout-1-recording.png`, `stop-layout-4-notes.png`). The `w1100` variant was
  re-run once after a launch that logged `no-window`. The blank sidebar list in the post-banner captures predates
  Polish 2 (same in `<scratch>/stop85/`).

## What to judge
1. **T83** `LibraryFolders.Filter`: stored-preference compatibility (nil / folder ID as before, Unsorted marker can't
   collide), rows/counts/visible(), drops on Unsorted unfile and already-unfiled are refused, View ▸ Show Folder,
   empty-list message, `recordingStarted` switch rules, Ask scope (no Folder scope under Unsorted; a Folder scope
   becomes All meetings when switching to Unsorted), File ▸ Rename/Delete Folder disabled under Unsorted, folder delete
   while shown. Tests cover the acceptance list; `sidebar-unsorted.png` in light and dark.
2. **T84** every overview item at body size (no .title lede left), eyebrow without detail, scratchpad line kept.
3. **T85** card subline ≈ 2 pt smaller, 0.8 opacity on selected and unselected, no clipping at 180 pt; the new
   `.cardMeta` role scales with text size and is used only there.
4. **T86** both toggles at the far top-right, sun/moon immediately left of Ask, open and closed, while recording, at
   900 and 1100 pt, sidebar open and closed; nothing in overflow; help, ⌘K and VoiceOver labels unchanged; the probe's
   measurement is sound (judge `StopLayoutProbe.toolbarCorner`, including its use of the private `_itemViewer` key).
5. **T87** ⋯ centred on the date line at the top-right; Process / Retry on the chips line's right; Audio details at
   the tab row's right with its badge; ⌘1/⌘2/⌘3 unchanged; no overlap at the narrowest detail width.
6. Regressions: anything else these commits broke (keyboard navigation in the sidebar, folder rename/delete flows,
   Ask scope state, VoiceOver order, light/dark parity).

## Report
Write your verdict to `<scratch>/validator/verdict.md`: **PASS**, **PASS WITH FIXES** or **FAIL**, then numbered
**must-fix** (acceptance not met or a real bug) and **should-fix** items, each with file:line and evidence, then a
list of hands-on checks you recommend the user do. Keep real meeting content out of the report.
