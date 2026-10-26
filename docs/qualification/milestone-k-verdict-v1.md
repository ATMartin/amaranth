# Milestone K verdict: PASS WITH FIXES

Must-fix: none.

Should-fix
1. Sidebar selected row: the orange status glyph (statusAttention) sits on the accent-blue selection and is almost invisible in light mode (real library, "Build Carolina check-in" row; sidebar glyph, T27/T43). Use white/primary on selected rows. Evidence: validator/l1.png, l2.png.
2. Recording tab Events list, App/Library/MeetingDetailView.swift:165-167: the source word ("mic") uses .secondary inside a row tinted statusAttention, so it renders pale orange in light mode (low contrast, est. below 3:1). Set it to an explicit secondary grey. Evidence: validator/l4.png.
3. Decision note says Details-on health popover keeps text; fine. But the note's "sidebar status glyph has a tooltip and VoiceOver label" was not verified by hover here (see Needs a person).

Needs a person
- Item 40 VoiceOver (source icons, flags, Pause/Resume names).
- Tooltips on icon-only controls (hover): sun/moon, flags, source icons, strip Pause/Resume.
- Recording strip and health popover live (needs Record), live view, onboarding, Match system following a Mac appearance flip while running, View-menu title refresh.

Checked
- swift test PresentationTests: 54 tests pass, incl. 5 PaletteContrast tests (status text vs window/underPage/own tint, link, discs vs white initials and window, distinct hues, toggle logic).
- ui-render exec: all ok true, toolbar step true in both appearances (toggle before Export); light and dark PNG sets identical (66 files each).
- Grep of App/ and Presentation/: no raw .green/.orange/.red/.blue in views; tones map to statusOK/Attention/Failed; only white initials on discs (contrast-tested). Speaker disc palette tested.
- Hands-on (real library, look-only, Debug build): toggle sun in dark, moon in light, in toolbar left of Export; tooltip title matches; Cmd+Shift+L flips and persists to "light", relaunch kept light; View menu item present and titled correctly; first toggle from Match system picked Light on a dark Mac; Settings shows Light/Dark/Match system and the new help text; Settings, models sheet, menu-bar menu follow the forced/system appearance. Notes (banner-less, Your notes/scratchpad collapsed), Transcript Columns and Bubbles with Cmd+D on/off, Recording tab, Settings Models/Recording/Appearance tabs legible in light and dark, no black boxes. Appearance restored to Match system, transcript style Columns; app quit.
- T45: source icons replace MIC/SYS; flags icon-only with .help + accessibilityLabel (TranscriptPane flag()); Pause/Resume icon-only with help; Stop and Save, Interrupted, failed notes and gap rows keep words (seen in renders). Banner/GroupBox chrome removed. Decision note accurate except it is numbered 0003 (task said 0002; user-approved).

## Resolution (2026-10-26)
- Should-fix 1: `MeetingStatusGlyph` uses the row's primary colour when `backgroundProminence` is increased (selected
  row on the accent fill); checked in the real app in light mode: white glyph on blue, orange on unselected rows.
- Should-fix 2: the Recording tab event's source word uses `secondaryLabelColor` explicitly, so it stays grey on
  attention rows (a two-word colour fix in an otherwise out-of-scope view, needed because T43 changed the row tint).
- Should-fix 3 and "Needs a person": checklist items 37–40.
