# Polish 2: changes after verdict v1

Verdict v1 (`polish-2-verdict-v1.md`): PASS WITH FIXES, no must-fix items.

- Should-fix 1 (applied): ui-render's folders step now switches from a folder with Ask on the Folder scope to Unsorted
  and requires the scope to become All meetings.
- Should-fix 2 (applied): `StopLayoutProbe.toolbarCorner` asks `responds(to: _itemViewer)` before reading the private
  key, so a macOS change fails the step instead of raising NSUnknownKeyException.
- Should-fix 3 (kept): the probe checks horizontal position only; the captures show the items in the title bar row.
- Should-fix 4 (kept): the empty Unsorted text is covered by `emptyListMessages`; no extra render.

After the fixes: ui-render passes in light and dark; scripts/stop-layout.sh passes 8/8 with all 24 toolbar-corner steps.
scripts/check.sh passed at T87 (the fixes touch only Debug self-test code).
