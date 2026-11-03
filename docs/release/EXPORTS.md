# Exporting meetings (Milestone S)

Amaranth can copy meetings out as files that any Markdown notes app, script or search tool can read. Nothing is sent
anywhere: you choose a folder, Amaranth writes files there, and that's all.

## How to export

- **File ▸ Export Meetings…** (⇧⌘E) starts with the meeting you have open, or the folder the sidebar shows, or all
  meetings. You can change it in the sheet: **This meeting**, any **Folder**, or **All meetings**.
- Right-click a folder in the sidebar ▸ **Export Folder…**, or use a meeting's ⋯ menu ▸ **Export ▸ To a Folder
  (Markdown and JSON)…**.
- Choose **Notes and transcript** or **Notes only**. The sheet shows how many meetings, transcripts and notes that is
  before you pick a folder. Audio is never included (use Export ▸ Original Audio… for that).
- Exports run in the background with a progress bar and **Stop**, then say what was written and what wasn't.

The single-meeting exports (Export ▸ Markdown…, Plain Text…, JSON…) are unchanged.

## What you get

```
<the folder you chose>/
  amaranth/
    README.md                 what this folder is
    manifest.json             every meeting here, with file hashes and status
    <meeting-id>/meeting.md   notes and transcript as Markdown, details in YAML front matter
    <meeting-id>/meeting.json the same meeting as data (format "amaranth-meeting", version 1)
```

- Folders are named by the meeting's ID, so renaming a meeting or two meetings with the same title never makes
  duplicates. The title is inside the files.
- `meeting.md` opens in any Markdown app; notes apps such as Obsidian show the front matter as properties. No plugin
  is needed. Times in the transcript and "see 00:12:03" in the notes are `amaranth://` links that open that line in
  Amaranth on this Mac. If the line was edited or removed since, Amaranth says the source changed and offers the
  meeting as it is now, instead of pointing at a different line.
- Web and e-mail addresses said in a meeting stay plain text: a zero-width space keeps notes apps from turning them
  into links, so the only links in an export are Amaranth's own. If you copy one out, it may carry that invisible
  character.
- Everything is exported **as Amaranth shows it**: corrected words, renamed speakers, deleted lines and trims applied.
  The original words you corrected or deleted are never exported. Lines you wrote are marked "your note"; generated
  lines that couldn't be fully checked are marked "uncertain"; notes made from an older transcript are marked stale;
  stretches with no transcript are listed as gaps.

## What a snapshot means

- An export is a **copy made when you export**. Later edits in Amaranth don't change it, and deleting a meeting in
  Amaranth doesn't delete its exported files. Export again to the same folder to update it.
- If you export into a **synced folder** (iCloud Drive, Dropbox…) or a notes vault, those apps may upload, index or
  keep their own copies. Amaranth can't reach or delete those.
- **Deleting transcript lines doesn't change the notes.** If the notes mention something you removed, edit or
  regenerate the notes too before exporting. Each export says so when it applies.

## Exporting again, and when something goes wrong

- Meetings that haven't changed aren't rewritten. Meetings that changed are updated in place.
- **Files you edited in the export folder are kept**, not overwritten; the result lists them. Move or delete your copy
  and export again to get Amaranth's version.
- If an export is stopped, the Mac loses power, or the disk fills up, the folder is marked unfinished
  (`amaranth/.export-in-progress.json`) and the manifest isn't updated. Export again to the same folder to finish; it
  replaces only files Amaranth itself wrote.
- Amaranth refuses a folder whose `amaranth` folder it didn't create, one from another Amaranth library, or a link.

## For tools and scripts

The formats, limits and citation links are specified in
[docs/decisions/0009-external-meeting-access-spec.md](../decisions/0009-external-meeting-access-spec.md) (§1a contract,
§2a retrieval, §4a export). `Benchmarks/AccessEval/read-export.py <folder>` checks an export with generic parsers.
Live access for desktop AI assistants (MCP) is planned as Milestone T and isn't part of this release.
