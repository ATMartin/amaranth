# Polish T74-T81 verdict: PASS WITH FIXES

Tests (Palette|MeetingStatusGlyph|LibraryAndAudioDetails|MeetingTitle|MeetingPeople): 23 tests, 6 suites passed.
ui-render: {"result":"pass"}, including toolbar (no model item), toolbar-recording at 900/1100, ask-clear.
Debug app's debug dylib contains T81 (removed popover string absent) and the T77 footer string.

## Must-fix
None.

## Should-fix
1. docs/decisions/ui/0004-inner-circle-identity.md:58 still says "Library: 160-320 pt (200 ideal)"; T80 made it 180 (LibraryView.swift sidebar column width).
2. App/Library/LibraryView.swift:78 the custom sidebar button's help says "(⌃⌘S)" but the button registers no shortcut; ⌃⌘S works only via the system View menu item. Not verified by me that the system item stays in sync with `columns` (stop-layout probe reportedly does toggleSidebar:; check by hand). Drop the glyph from the help or register nothing and say so.
3. App/Shared/MeetingCommands.swift:79 Export submenu is disabled for the whole submenu when no transcript, so Original Audio… is unavailable for an unprocessed meeting (the main case where only audio exists). Matches user decision for T79, but worth confirming that was intended for audio.
4. MeetingCommands.swift:112,120 `.audio` is a case of MeetingExport.Format that is handled by an early return and then listed in dummy `case .json, .audio` arms; split audio out of the enum to avoid dead arms.
5. Card context menu "Show Details" toggle (MeetingCommands.swift ~76) flips the global preference, not that card's meeting; harmless but surprising from a non-open card.
6. T74: measured ratios confirm floors (accent on surface 3.12 >= 3, on Selection 2.517 >= 2.5, cream on accent 3.66; light AA kept; catalog matches). Selection margin is only 0.017; any tweak breaks it. Exception is documented in ADR and tests and limited to dark accent pairs. I did not enumerate accent text on status-tinted strips (not in the tests); spot check by eye.

## Per-task notes
- T74 OK. T75 OK (renders: no title, no capsules, Canvas bar, list icon, small sun/moon; toolbar items 4). T76 OK vs .am-record (6 pt, Surface, border, Danger dot, labels intact). T77 OK (no model references in toolbar, tab persisted via @AppStorage, .checking maps to ready). T78 OK (clearAsk empties/focuses; Esc handles typed text without results). T79 OK: one MeetingActionsMenu, rename/delete presented once at MainView, playback stops only if the deleted meeting is the selected one, ⌘D registered once (View menu), ⌘E via library.export. T80 OK (truth table tested; header keeps full glyph; 180 ideal). T81 OK.

## Hands-on checks for the user
- Click sidebar footer with no model: Settings opens on Models; Recording Settings... opens Recording tab while Settings is already open.
- View > Hide Sidebar and ⌃⌘S sync with the list-icon button; Esc/x in Ask refocuses field.
- Right-click a closed card > Export > Markdown saves that meeting; rename/delete from a card with sidebar closed; delete of the open meeting stops playback.
- Dark accent legibility on small links/tabs; Record button hover/pressed states with .plain style.
