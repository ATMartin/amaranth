# Milestone J: changes after verdict v1

Verdict v1 (Sonnet validator, `milestone-j-verdict-v1.md`): **PASS WITH FIXES**, no must-fix items.

1. Should-fix 1 (`moveMeeting` race): the folder-exists check and the write now run in one transaction
   (`Storage/Folders.swift`), so a `deleteFolder` can't land between them and leave a dangling `folder_id`.
2. Should-fix 2 (Ask "Meeting" with no meeting open): with a folder shown and no meeting open, the scope switch offers
   Folder | All only (`AskScope.options(folderShown:meetingOpen:)`; test added), so no segment silently searches
   everything.
3. Informational 3 (open meeting stays selected when the filter changes): kept on purpose. Switching the filter only
   changes the list; the meeting on screen stays open (like Granola, and like the detail pane staying put while
   recording into another folder). ↑/↓ then start from the first shown card.

After the fixes: Storage, Presentation and DataLifecycle tests pass; the Debug build succeeds; ui-render passes in
light and dark.
