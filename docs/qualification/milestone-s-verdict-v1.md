# Milestone S (T97–T100) independent validation — verdict v1

**Verdict: PASS WITH FIXES.** (Sonnet validator, 2026-11-03; condensed from its report.)

## Must-fix
- **M1. Search paging not stable** (`MeetingAccess/Retrieval.swift`, `want`/`candidates`): the FTS candidate pool grew
  with each page (`max(200, want*10)`), so later pages were ranked from a different candidate set. A 60×1,000 library
  paged with limit 20 showed 6–27 duplicate passages and 7–21 score inversions per query. Fix: rank once with fixed
  parameters (k = 100, constant candidates) and slice pages; test with more than 200 matching rows.
- **M2. 64 KiB ceiling not enforced for search, list and metadata.** A single ~140 KB note passage gave a 141,499-byte
  search response; 50 rows with 5,000-character titles and 20 people gave a 776,684-byte list; a 100,000-character title
  and 3,000 people gave 183,837 bytes of metadata, and `itemBudget` went negative, so transcript paging crawled one
  character per call. Fix: shorten or fragment passage lines with a marker, cap strings and arrays in the list and
  metadata projections (with a limitation), guard `itemBudget`, and add tests asserting size ≤ 64 KiB per operation with
  hostile sizes.

## Should-fix
- **S1.** Export into a folder left incomplete by another library is accepted: the ownership check reads only
  `manifest.json` and ignores the in-progress marker's `libraryID`. Fix: refuse unless the marker's library matches.
- **S2.** Markdown/Obsidian inertness: bare URLs, emails and `www.` stay literal and are autolinked by Obsidian/GFM;
  `%%hidden%%`, `==hl==`, `$$x$$` and `^blockid` pass through. `read-export.py` (CommonMark, no linkify) can't see
  autolinks. Fix: break autolinks and escape `% = $ ^` in the bulk path, and add a linkify check (or document it).
- **S3.** `record-under-load` checks only segment boundaries, so a drop inside a segment is invisible, and total frames
  aren't compared with elapsed time. Fix: check last − first = frameCount − 1 per segment and totals ≈ seconds × 48,000.
- **S4.** Cursors aren't bound to the access scope (a list cursor made under `.all` is accepted under `.meetings`). It
  leaks nothing today, but a grant change mid-listing would skip or repeat rows silently. Fix: include a scope digest.

## Nice-to-have
- N1 `purgeMeeting`, provisional `publishTranscript` and `upsertJob` don't bump the content generation (listing state).
- N2 Export renames without fsync (a power loss could leave a zero-length file later treated as user-modified).
- N3 README.md isn't in the manifest (a future README change would be kept as "user-modified").
- N4 `Retriever` binds one parameter per in-scope meeting (fine at 200; large libraries depend on SQLite's limit).
- N5 A hashless transcript URL without `word` resolves to the segment's first line; require `word` (or `h`).
- N6 After a per-meeting write error the entry keeps old file hashes, even for a file already overwritten.
- N7 `SourceURL.string` doesn't validate IDs; assert identifiers so an odd ID can't break a Markdown link.

## What held up
- **Snapshot redaction:** no raw revisions, summary body, emails or paths anywhere in the snapshot.
- **Source links:** of 38 hostile URLs, 22 were rejected as invalid. Edited, deleted, trimmed and other-revision sources
  resolve as `changed`, never to another line. App link handling only navigates.
- **Cursors and scope:** forged and foreign cursors are refused, and a generation change asks for a restart. Scope is
  applied inside the FTS query, before ranking.
- **Export publication:** staging, manifest last, marker and journal kept on cancel, user edits kept. Unknown, foreign
  and linked destinations, and linked meeting folders and files, are refused. A read-only destination is reported
  clearly, and an unchanged re-run writes nothing.
- **Hostile metadata:** 0 failures through `read-export.py`.
- **Single-meeting export:** unchanged.
- **T98 eval re-run:** identical numbers. The u06 re-specification is legitimate and disclosed. The synthetic corpus
  makes lexical recall easy by construction.
- **Scale:** a smaller sample is consistent with the 200-meeting claims.
- **T100 docs:** honest about their limits.

## Needs a person
- The Obsidian vault window after the disclosed side effect.
- A real call recorded during a large export.
- Release app checks: URL registration, the File menu item and ⇧⌘E, the folder's Export Folder…, the meeting ⋯ item.
- In the export sheet: Stop, progress, VoiceOver and keyboard.
- A real-library export opened in Obsidian (bare URLs, `%%`).
- An `amaranth://` link clicked from another app, with Amaranth closed and with it open.

## What the validator ran
- Filtered `swift test`: all passed.
- Release `amaranth-access`: seed-demo / snapshot / resolve (38 URLs); seed-hostile / export twice / read-export.py;
  seed-eval / eval; seed-scale 60×1000 / scale.
- Its own probe package: size budgets, cursor forgery and cross-scope cursors, paging duplicates and the candidate-pool
  root cause, and a bulk-export matrix.
- Not run: record-under-load and the disk-full image (it relied on the evidence and the code instead). It touched
  nothing outside its scratch folder.
