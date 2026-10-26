# Milestone K: brief for the independent validator

You are validating **Milestone K ("Light mode and lightweight visual language", T43–T45)** of Amaranth, a local macOS
meeting recorder and transcriber. Repo: `/Users/alex/sandbox/amaranth-v2`. Backlog with each task's deliverables,
acceptance and fallback: `docs/implementation-tasks.json` (ids T43, T44, T45). Source of the tasks:
`docs/decisions/0005-design-review-2026-10-23.md` and `docs/design-review/2026-10-23/transcript.md` (13:03–14:11,
08:05–08:20). One commit per task: `git log --oneline 13c64dd..HEAD` (T43 4a4c988, T44 0602dde, T45 5429849).
Decision note: `docs/decisions/ui/0003-visual-language.md`. Evidence: `docs/qualification/evidence/2026-10-26/appearance/`
(light/dark renders of every screen, toolbar-order.jsonl) and `.../t45/` (before/after). Hands-on checklist:
`docs/qualification/ui-manual-checklist.md` (new items 37–40; earlier items 1–36).

## User decisions (2026-10-26)
- All of K in one go, one commit per task, hands-off; stop after K.
- "Match system" is the default. Shortcut ⌘⇧L. Committed screenshots use fixtures only.
- The task says decision note 0002; 0002 was already taken (bubbles), so it is 0003.
- Hands-on pass: the user granted Terminal Accessibility and quit their own Amaranth so you can drive the **Debug**
  app on the user's **real library, look-only** (rules below).

## Ground rules
- Be adversarial and independent. Check claims against code, tests and evidence, or by running things.
- **Don't** modify source or docs; scratch files only under `/private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/ff774fb9-5281-430e-b30a-7666573c0253/scratchpad/validator/`. Don't run `xcodegen` or `xcodebuild` (the Debug
  build in `build/DerivedData` is the final T45 code), the perf-suite, or any `capture-*` self-test.
- `rm` is aliased; use `/bin/rm -f`.
- You may run `swift test --scratch-path /private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/ff774fb9-5281-430e-b30a-7666573c0253/scratchpad/validator/build --filter PresentationTests` (new: PaletteContrastTests) and the
  render self-test (exec the binary directly, 300 s timeout):
  `build/DerivedData/Build/Products/Debug/Amaranth.app/Contents/MacOS/Amaranth --self-test ui-render --self-test-output /private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/ff774fb9-5281-430e-b30a-7666573c0253/scratchpad/validator/png`
  → `png/light/` and `png/dark/`; every line's ok must be true, including the `toolbar` step.

## Hands-on (real app, look-only)
Launch: `open -n build/DerivedData/Build/Products/Debug/Amaranth.app`. Drive it with `osascript` / System Events
(UI scripting works) and capture with `screencapture -x` or `screencapture -l <windowid>`. Quit it at the end
(Amaranth ▸ Quit, or kill by PID from `pgrep -f "Debug/Amaranth.app/Contents/MacOS/Amaranth$"`; never by name).
- **Never**: press Record (or ⌘⇧R), Pause/Stop, rename, merge or assign speakers, Correct Text, edit Your notes or the
  scratchpad, Regenerate/Generate notes, Retry/Process, Delete anything, Export, or install/remove models. Don't write
  under `~/Library/Application Support/Amaranth/`.
- **Allowed**: select meetings, switch tabs (⌘1–⌘3), ⌘D, hover for tooltips, open/close menus, open Settings and
  change only Appearance, Text size and Transcript style, use the sun/moon toggle and ⌘⇧L, open the models sheet and
  close it, expand/collapse Notes sections, open the menu-bar menu.
- Privacy: the library holds the user's real meetings. **Never quote transcript or notes text** in your report;
  meeting titles are fine. Keep real-content screenshots in `/private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/ff774fb9-5281-430e-b30a-7666573c0253/scratchpad/validator/` only.
- Settings are restored for you afterwards from a backup; still put Appearance back to Match system when done.

Check in **both** Light and Dark (and Match system following the Mac): checklist items 37–40, plus a look-only pass
over earlier items that concern visuals (sidebar, header, tabs, transcript Columns/Bubbles with ⌘D on/off, Notes,
Recording tab, Settings tabs, models sheet, menu-bar menu, tooltips of icon-only controls). Items that need recording,
editing or VoiceOver go into a "Needs a person" list.

## What to judge
1. T43: every colour in App/ and Presentation/ is semantic or a palette token (grep for `.green`, `.orange`, `.red`,
   `.blue`, hard-coded tints); contrast test is real and covers what is used; status meanings preserved; setting is
   persisted and applied to all windows incl. Settings and the menu-bar menu; ui-render covers every screen named in
   T43's acceptance in both appearances. Any dark-only artefact (black boxes, invisible text) in light mode?
2. T44: toggle placement (trailing, before Export), symbols, tooltips, menu item + ⌘⇧L, persistence across relaunch,
   "Match system" still in Settings, first click from Match system picks the opposite.
3. T45: no safety-relevant state (missing audio, permission denied, failed processing) became icon-only without a
   tooltip **and** an accessibility label; text badges replaced where meaning survives; less chrome; icon sizes;
   decision note accurate.
4. Regressions in anything else (Bubbles, evidence jump, text sizes, toolbar recorder).

Write your verdict to `/private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/ff774fb9-5281-430e-b30a-7666573c0253/scratchpad/validator/milestone-k-verdict.md`: PASS / PASS WITH FIXES / FAIL, a must-fix list, a should-fix
list, a "Needs a person" list, and what you checked. Return the same summary.
