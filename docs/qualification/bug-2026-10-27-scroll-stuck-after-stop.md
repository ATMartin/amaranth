# Bug: window content stuck scrolled below the content after Stop (2026-10-27)

Status: **fixed (T67)**. Reproduced in the real window; cause and fix under "Resolution" at the end.

## Report (user, 2026-10-27)

"I just used the latest build for a meeting and it transcribed great, but after stopping the call the UI is now
'stuck' scrolled down to well below the content. Both the left nav bar and the main column are fixed to a lower point
and I can't scroll up. I can see the bottom of the generated notes for my last call, but that's it. When I try to
scroll I see the usual Apple 'drag' effect as content comes back into frame, but it rubber-bands back up out of view
as soon as I let go."

Observed, in short:
- Trigger: stopping a real recording (transcription itself fine; notes were generated).
- Both the sidebar and the detail column rest at an offset below their content; only the end of the notes is visible.
- Scrolling rubber-bands: the content is pulled into view while dragging and snaps back on release, so the scroll
  views treat the wrong position as their resting position.

## Facts gathered so far (no conclusions)

- `/Applications/Amaranth.app` is dated 2026-10-26 08:31 (build 1), which predates the window fixes in 14d4fd4
  (2026-10-26 17:43: strip moved to the detail toolbar, window clamped to the visible area, content no longer sets the
  window's minimum height) and Milestones M–O. The DMG built from f5321bb was not installed. Which build the user
  ran still needs confirming.
- The saved frame for the `main` window is `268 0 1100 1084` on a `1728 × 1084` screen. (Correction: the second
  rectangle in a saved frame is the screen's visible area, so the window was exactly the full visible height, not
  taller.)
- The app was not running when this was written, so the stuck window couldn't be inspected.

## Suspects to check first

1. **A stale top content inset.** Both columns rest at the same wrong offset and rubber-band to it, which is what a
   too-large `contentInsets.top` (the safe area under the toolbar) does to every `NSScrollView` in the window. Stop
   removes the recording strip from the toolbar (and closes any event prompt popover), changing the toolbar's
   height; if the safe area isn't recomputed, the insets stay wrong.
2. **The window frame.** A window taller than the visible area (see the saved frame) or a `setFrame` from
   `WindowFitsScreen.fit` during the Stop layout change could leave the hosting view's layout out of step with the
   window.
3. **The tab switch at Stop** (T32: transcript while recording, notes once they exist) together with the live
   transcript's follow-the-bottom `ScrollViewReader`: would explain the detail column but not the sidebar.

## To collect

- Which build was running (installed app vs. the f5321bb DMG vs. a Debug build), window size, sidebar open or not,
  full screen or not, and whether the calendar prompt was showing at Stop.
- Whether resizing the window, toggling the sidebar, selecting another meeting, or relaunching clears it.

## Fix acceptance (T67)

- Reproduced (ideally in ui-render or a scripted recording with the real window), then fixed at the cause.
- After Stop, both columns start at the top of their content and scroll freely, at 900 pt and 1100 pt wide, sidebar
  open and closed, window at the screen's full visible height, with and without the event prompt.
- A ui-render or self-test check that fails on the old behaviour; hands-on checklist item for the user.

## Resolution (T67, 2026-10-27)

- **Build:** the user ran the DMG built from f5321bb (after the 14d4fd4 window fixes). Relaunching cleared it.
- **Reproduced** with `scripts/stop-layout.sh`, which drives the real `Window` scene of a Debug build (Debug-only
  `--debug-stop-layout`, `App/Launch/StopLayoutProbe.swift`) on a throwaway fixture library at the screen's full
  visible height: Record → stopping → Stop → the banner → Notes. It logs the window and every scroll view's frame and
  fails a step when a scroll view reaches outside the window. Before the fix, at 1100 pt, both columns' scroll views
  were 1,958 pt tall in a 1,084 pt window (origin −463), so their tops were about 411 pt above the window's top edge.
  That matches the report: only the bottom of the notes showed, and scrolling rubber-banded because the scroll views
  were already at their top.
- **Cause:** none of the three suspects. Stop sets the result line "Saved N segments (… s) to <meeting folder path>"
  in the recorder banner. The banner was a `safeAreaInset` outside the detail column's `fillsOfferedSpace()`, and its
  text uses `fixedSize(vertical:)`. When SwiftUI computes the split view's minimum height, it measures the banner at a
  near-zero width, where the long path wraps to hundreds of lines. That minimum (about 1,960 pt) exceeded the window,
  and the split view was laid out at that height and centred, pushing both columns' tops off screen. Isolating the
  steps showed that removing the strip, the Stop selection/tab switch and the calendar prompt changed nothing; setting
  the banner line alone triggered it. Any long banner line (recovery message, error) could do the same.
- **Fix:** the banner moved inside the measured area (`App/Library/LibraryView.swift`): it is now a `safeAreaInset` of
  the detail content *before* `fillsOfferedSpace()`, so it is laid out at the column's real width and can no longer
  set the split view's minimum height. No scroll position is forced.
- **Check:** `scripts/stop-layout.sh` runs 1100 and 900 pt × sidebar open/closed × with/without the calendar prompt.
  All 8 variants fail with the old layout and pass with the fix. Hands-on checklist item 59 in
  `docs/qualification/ui-manual-checklist.md`.
