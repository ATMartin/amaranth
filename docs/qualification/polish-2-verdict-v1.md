# Polish 2 (T83-T87) verdict: PASS WITH FIXES (no must-fix; four should-fix items, all small)

Independently run: `swift test --filter "LibraryFolders|AskAnything"` (14 tests, 3 suites, all pass); headless `ui-render`
(ends `{"result":"pass","test":"ui-render"}`). Read: check88.log (BUILD SUCCEEDED, ALL AUTOMATED CHECKS PASSED, exit 0),
all 8 stop87 `out.jsonl` files (every toolbar-corner step ok:true, hidden:"" and result pass) and the captures
`stop-layout-0a-ask-closed`, `-1-recording`, `-4-notes` at 900 pt. I did not launch the app or run xcodebuild/stop-layout.

## Must-fix
None. Every acceptance item I could check against code, tests or renders holds.

## Should-fix
1. Ask-scope rule under Unsorted is only partly tested. LibraryModel.swift:17-21 (the `folderFilter` didSet) turns a
   Folder scope into All meetings when switching to Unsorted, and AskScope.options(folderShown: false) gives
   Meeting | All (asserted at UIRenderSelfTest.swift:319-320). But no test switches from a `.thisFolder` scope to
   `.unsorted` and checks `askScope == .allMeetings`. The logic reads correctly (folderID == nil -> allMeetings);
   a regression would go unseen. Add a LibraryModel-level check in ui-render, next to line 318.
2. `StopLayoutProbe.toolbarCorner` (App/Launch/StopLayoutProbe.swift:75-80) uses `item.value(forKey: "_itemViewer")`.
   If that private key ever vanishes, KVC raises NSUnknownKeyException (a crash, not a failed step). It is
   DEBUG-only and works today (the SwiftUI items have `view == nil`, so the fallback is what produces the measured x
   ranges). Guard it with `responds(to:)`, or catch via an ObjC-safe wrapper, so a macOS change reads as a probe failure.
   Also, items are matched by label prefix/suffix ("Ask", "Switch to"), which is fragile to renames. Acceptable, but
   the match should fail loudly (it does: a nil frame gives ok=false).
3. The probe checks horizontal position only: the Ask toggle within 40 pt of the window edge, and the sun/moon
   immediately left of it (gap under 24 pt). Measured: Ask 1054-1092 in a 1100 pt window, sun/moon 1010-1045;
   810-845 and 854-892 at 900 pt. Nothing checks that the items sit in the titlebar row. The captures show they do.
   Not blocking.
4. ui-render's Unsorted check asserts only that the visible list is non-empty and all unfiled. The Unsorted count
   and the empty-list text are covered by unit tests (`rowsCountsAndFilter`, `emptyListMessages`), and the
   sidebar-unsorted capture shows count 2 (All 5, Acme 2, Hiring 1), so this is fine. A render of the empty
   "Every meeting is in a folder." state would be a nice extra.

## Per-task findings
1. T83 (checked in code, tests and `sidebar-unsorted.png`, dark; light renders pass in the same run).
   - Stored preference: `Filter.stored` is nil for All (as before), the folder ID for a folder, and "@unsorted" for
     Unsorted. `init(stored:)` maps nil and "" to All. A folder ID is a UUID, so it cannot collide with "@unsorted".
     `filterPreferenceRoundTrips` covers this.
   - Rows, counts and visible() are tested: names [All, Unsorted, Acme, Hiring], counts [4,2,2,0], and Unsorted lists
     only unfiled meetings, newest first.
   - Drops: `Row.folderID` is nil for Unsorted, so a drop unfiles. Already-unfiled meetings are filtered by
     `dropMoves` (tested: empty result, no dialog). Unsorted has no context menu (LibraryView.swift:236, the folder
     rows only), so there is no rename/delete on it.
   - View > Show Folder lists All, Unsorted, then the folders (MeetingCommands.swift:53-57). File > Rename/Delete
     Folder stay disabled under Unsorted because `filteredFolder` is nil (LibraryModel.swift:313).
   - Folder delete while shown: `.folder(id)` falls back to `.all`. `validFilter` leaves Unsorted alone (tested).
   - `recordingStarted`: `filter(_:showingNewMeetingIn:)` keeps Unsorted for an unfiled recording and switches to
     the folder for a filed one (tested).
   - Empty-list text is correct for each case (tested).
   - Ask scope: no Folder scope under Unsorted (see should-fix 1). Row ids are distinct ("", "@unsorted", UUID).
2. T84: the `role:` parameter and `.title` lede are gone (NotesPane.swift:129-141, 196-207). Every item renders with
   `.appFont(.body)`. The eyebrow is `Eyebrow(text: "Meeting notes")` with no detail, and the scratchpad `Label`
   remains when `influencedByPersonalNotes`. `main-recording` / `stop-layout-4-notes` show one text size for the
   overview, decisions and next steps. Met.
3. T85: `.cardMeta` is 9 pt (caption2 was 11). Colour is brandText (selected) or brandSecondary (unselected) at
   opacity 0.8. The role is used only at LibraryView.swift:359 and goes through `appFont`, so the text-size scale
   applies. No clipping in the 180 pt `sidebar-unsorted.png` (wrapped titles, meta line intact). Documented as the
   one exception to the 11 pt floor. Met.
4. T86: the Ask toggle is `bubble.left`. Labels (Show Ask / Hide Ask), help text and the ⌘K hint are unchanged
   (LibraryView.swift:54-61). The sun/moon moved into the same group before it. At 900 and 1100 pt, sidebar open and
   closed, with and without the calendar prompt (8 variants x 3 steps = 24 steps) the probe reports ok:true,
   `hidden` empty, Ask within 8 pt of the right edge and sun/moon directly left (9 pt gap). The captures show
   moon then bubble at the far top-right with the Ask pane open, closed and while recording; the recording strip
   stays in the middle. The 900 and 1100 pt x ranges are identical across the idle, Ask-closed and recording
   steps. Met.
5. T87: the ⋯ menu is in an HStack with the date and a Spacer, centred, at the header's top-right
   (MeetingDetailView.swift:49-57). Process / Retry stay at the right of the chips line (Spacer, then the
   buttons; `actionsMenu` removed from there). `UnderlineTabs.trailing` puts Audio details after a Spacer, with the
   same badge/help/accessibility (BrandStyles.swift:94-128); the tab order is unchanged, and the ⌘1/⌘2/⌘3 commands
   are not touched by the diff. `header-narrow.png` (light) shows no overlap: ⋯ top-right, Process right, Audio
   details right. The audio-issue badge path is unchanged code, but no capture exercises it in the new position
   (see hands-on 4).
6. Regressions: nothing found. Sidebar keyboard navigation and card selection code is untouched, and
   `FolderFilterList` still uses `rows.prefix(2)` / `dropFirst(2)` correctly. Light/dark parity: the ui-render
   passes cover both. VoiceOver order for tabs is unchanged (Notes, Transcript, Audio details).
   Not exercised: a live drag-and-drop onto the Unsorted row (the hands-on list).

## Hands-on checks recommended (real app, user's library)
1. Click Unsorted: only unfiled meetings show. Drag a filed card onto Unsorted (it unfiles) and an unfiled card onto it
   (nothing happens, no dialog).
2. With Unsorted shown, start a recording with no folder (the filter stays) and one into a folder (the filter
   switches to that folder).
3. Open Ask with a Folder scope on a folder, then click Unsorted: the scope shows All meetings, and Meeting | All
   only. Relaunch with Unsorted selected: it is remembered.
4. Open a meeting with an audio-issue badge: Audio details sits at the tab row's right with the exclamation mark,
   and ⌘1/⌘2/⌘3 still switch tabs. Narrow the window to 900 pt with both panes open.
5. Toolbar: sun/moon then the speech bubble at the top-right, Ask pane open and closed, while recording, with the
   sidebar hidden; hover for help, press ⌘K, check VoiceOver reads "Show Ask / Hide Ask".
6. Look at the card time line at your usual text size and at the largest Settings text size, selected and unselected,
   in light and dark.
7. File > Rename Folder / Delete Folder are greyed while Unsorted is shown. View > Show Folder lists Unsorted.
