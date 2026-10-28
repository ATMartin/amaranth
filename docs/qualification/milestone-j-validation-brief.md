# Milestone J (T39–T42, folders): brief for the independent validator

You are validating **Milestone J (folders)** of Amaranth, a local macOS meeting recorder: single-level folders for
meetings (not tags), managed in the sidebar.

- **Repo:** `/Users/alex/sandbox/amaranth-v2`.
- **Backlog:** `docs/implementation-tasks.json` (T39–T42: context, deliverables, acceptance, fallback).
- **Commits (one per task):** `git log abb24f1..HEAD`. Each commit message lists what changed and any deviation.
- **Design review source:** `docs/decisions/0005-design-review-2026-10-23.md` (folders row), and
  `docs/design-review/2026-10-23/granola-note-header-folder-icon.png`.
- **Manual checklist:** `docs/qualification/ui-manual-checklist.md` items 67–69 (hands-on steps left to the user).

## User decisions (2026-10-28)
- **Sidebar is a Granola-style folder filter, not collapsible folder sections** (deviates from T40's deliverable text
  on purpose): "All meetings" row + one row per folder with a count; clicking a row filters the day-grouped card list.
  "All meetings" lists every meeting (filed or not); dropping on it (T41) unfiles. Because of this, T40's "collapse
  state persisted per folder" became "the shown folder is persisted". Judge the implementation against this decision.
- Optional T42 is included in full (default folder in the Record popover and Settings → Recording; Ask folder scope
  while a folder is shown).
- Validation is on code, tests and renders only: the user's Release app is running on the real library (schema v4).
  **Don't launch a second instance of either build**, and don't touch `~/Library/Application Support/Amaranth`.
  After your verdict the Release build will be installed and will migrate the real library to schema v5.

## Ground rules
- Be adversarial and independent; check claims against code, tests and renders.
- `<scratch>` below is `/private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/613a6916-dce9-4bb3-ba01-9750c04fa728/scratchpad`.
- **Don't** modify source or docs. Scratch files only under `<scratch>/validator/`.
- **Don't** run `xcodegen`/`xcodebuild`, `scripts/check.sh` or `scripts/stop-layout.sh`; don't `open` the app.
  `rm` is aliased; use `/bin/rm -f`.
- You may run `swift test --scratch-path <scratch>/validator/build --filter "StorageTests|PresentationTests|DataLifecycleTests|recordingStartsInTheChosenFolder"`
  and the headless render:
  `timeout 300 build/DerivedData/Build/Products/Debug/Amaranth.app/Contents/MacOS/Amaranth --self-test ui-render --self-test-output <scratch>/validator/png`
  (temporary store, never the user's library; must end with `{"result":"pass"}`; it saves and restores the
  `sidebarFolderFilter` preference). Offscreen renders leave the split view's sidebar and inspector blank in
  `main-*.png`; use `sidebar*.png`, `ask-pane-*.png`, `header-*.png`, `record-options.png`.
- Evidence already gathered (read, don't re-run): `<scratch>/check-t42.log` (scripts/check.sh at T42),
  `<scratch>/stop-j/` (scripts/stop-layout.sh, 8 variants).

## What to judge
1. **T39 storage**: migration v4→v5 on a populated library (no data loss; older rows decode unfiled); name rules
   (trim, non-empty, unique ignoring case incl. non-ASCII; self-rename in another case); delete-folder never deletes or
   alters audio/transcript/notes (test asserts byte-identical other tables, meeting rows differ only in folder);
   stale writers (recorder, recovery, rename, processing results, purge) can't drop or resurrect a folder; no foreign
   key on folder_id — is consistency still guaranteed by every writer?; JSON export `folder: {name}` only when filed,
   TXT/MD unchanged; contract version not bumped.
2. **T40 sidebar**: rows/counts/filter correctness; filter persisted and reset when its folder is deleted; New Folder
   from +, background menu, ⇧⌘N; Rename/Delete (confirmation says meetings stay); Move to Folder ▸ / Remove from
   Folder in the shared meeting menu and the header folder chip; keyboard paths (menus, ↑/↓ over shown meetings);
   duplicate names surface as the existing alert; Ask results show the folder; sheets/dialogs not presented twice;
   `folderRequest` state doesn't leak.
3. **T41 drag and drop**: payload type declared and private; drops on folder rows and All meetings; no-op/invalid
   drops refused without dialogs; hover highlight; nothing else in the sidebar broke (buttons still click, context
   menus still open — reason from code, since you can't drag).
4. **T42**: recording starts in the chosen folder (popover per-recording, Settings default, reset after each
   recording like sources); a deleted default folder never blocks Record; filter switches so the new card is visible;
   Ask "This folder" scope (search + answers retriever + follow-up history reset), shown only with a folder shown,
   falling back to All meetings; labels fit the 250 pt pane.
5. Regressions: Ask scopes for meetings/all, header layout at 900 pt (ViewThatFits variants), the Record popover
   height, VoiceOver labels, dark/light parity, the ui-render fixtures and existing steps.

## Report
Write your verdict to `<scratch>/validator/verdict.md`: **PASS**, **PASS WITH FIXES** or **FAIL**, then numbered
**must-fix** (acceptance not met or a real bug) and **should-fix** items, each with file:line and evidence, then a
list of hands-on checks you recommend the user do. Keep real meeting content out of the report.
