# Milestone J validation verdict: PASS WITH FIXES

Evidence: swift test (StorageTests|PresentationTests|DataLifecycleTests|recordingStartsInTheChosenFolder) all pass; headless ui-render ends {"result":"pass"} (light and dark; ask-folder step ran; sidebar-folder, ask-pane-folder, record-options, header renders inspected). Code reviewed for T39-T42 against the brief and the 2026-10-28 filter decision.

## must-fix
None.

## should-fix
1. Storage/Folders.swift:80-85 (moveMeeting): the folder-exists check and the update are two separate store calls (withDB, then updateMetadata at MeetingStore.swift:150). A deleteFolder between them leaves meetings.folder_id (and JSON folderID) pointing at a missing folder; there is no foreign key and nothing heals it (UI would show the meeting in All meetings, chip "Not in a folder", counted in no folder). Narrow race (also reachable via LibraryModel.createFolder(moving:) and a drop racing a delete), but the schema comment promises the store keeps it valid. Fix: do the check inside updateMetadata's transaction.
2. App/Library/AskAnythingView.swift:33: with a folder shown and no meeting open, the "Meeting" segment is enabled, but effectiveScope falls back to all meetings (placeholder says "across all meetings"). Keep the Meeting segment disabled or hidden without an open meeting.
3. Informational / optional: switching the folder filter (LibraryModel.folderFilter) leaves the open meeting selected even if it is not in the shown folder; up/down then jumps to the first shown card (LibraryView move(), LibrarySidebar). Acceptable, but confirm it is the intended Granola behaviour.

## Verified (no issues)
- T39: v5 migration is additive (new table, nullable column, index; v4 migration test exists); NOCASE index plus Unicode-aware compare (checked Straße/STRASSE, accented, Greek final sigma fold equal); trim, empty, duplicate and self-rename-in-other-case tests; deleteFolder test asserts other tables byte-identical and meeting rows differing only in folder; upsertMeeting keeps stored folder, drops a missing folder for new rows; trimCapture, notes, processing writers decode and re-encode stored JSON so they keep folderID; purge clears folder_id; JSON export folder only when filed; Meeting JSON additive, contract version unchanged.
- T40: rows/counts/visible/validFilter pure and tested; filter persisted ("sidebarFolderFilter") and reset on delete (reload and deleteFolder); New Folder from +, background menu, File menu (shift-cmd-N, guarded by sheetOpen); one sheet and one confirmation in MainView (single Window scene, so not presented twice); folderRequest cleared on dismissal; delete message says meetings stay; move menu in card menu, header menu and chip; errors go through library.error alert; Ask results show the folder.
- T41: private exported UTI declared in project.yml and Info.plist; payload is the ID only; dropMoves refuses no-op, unknown, repeated and deleted-folder drops with no dialog; hover highlight present. Drag/click coexistence reasoned from code only.
- T42: RecordingSession gets folderID, store drops a missing folder; popover choice resets via loadDefaults at finish (and at start when not customized); stale default reads None and never blocks Record; recordingStarted switches the filter; Ask Folder scope covers search, anyTerm fallback, Retriever, history reset on folder change (AnswerModel), fallback to All on folder nil; labels shortened to Meeting | Folder | All and fit in the render.
- Regressions: header 900 pt, record popover, dark/light parity, existing ui-render steps all fine in render.

## Recommended hands-on checks (user)
1. After the Release build migrates the real library to v5: back up first, confirm all meetings still list and open, All meetings count matches the previous total.
2. Create a folder from +, shift-cmd-N and a meeting's Move to Folder > New Folder; try a duplicate name in a different case and with an accent.
3. Drag a card onto a folder, onto All meetings (unfiles), and onto the folder it is already in; confirm clicking and right-clicking cards still work, and that dragging out to Finder does nothing.
4. Delete a folder holding meetings: they stay in All meetings; filter falls back to All.
5. Set Settings > Recording > Save to folder, record a short clip, check it files and the sidebar switches; delete that folder and record again; use the popover to choose another folder and confirm it resets after Stop.
6. With a folder shown, ask in Meeting / Folder / All scopes; confirm answers and sources come only from that folder, and that the header folder chip (name, narrow icon-only) and VoiceOver labels read well at 900 pt.
