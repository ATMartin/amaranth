# Milestone S: changes after verdict v1 (2026-11-03)

Every finding of `milestone-s-verdict-v1.md` was fixed, except N4, which is recorded as a known limit. Regression
tests are in `Tests/DataLifecycle/ValidatorFixTests.swift` unless noted.

| Finding | Change | Test / evidence |
|---|---|---|
| M1 search pages | `searchMeetings` ranks once per request with fixed parameters (`Retriever` k = 100, `candidates` = 1,000); pages slice that list (`MeetingAccess/Retrieval.swift`) | `searchPagesAreSlicesOfOneRanking`: 12 meetings × 20 matching lines (240 rows, more than the old pool), paged to the end; no repeats, ranks 1…n, first page = unpaged result. Re-run eval and scale: `t98-retrieval-report.md` "After the validator's fixes" |
| M2 64 KiB | `ProjectionCaps`: titles 512 chars, names 100, lists 50 in list rows and get metadata, marked `shortened` with a limitation; list pages shrink until they fit; search lines over 1,000 chars shortened and marked; `itemBudget` refuses (`internal`) below 4 KiB instead of going negative | `everyOperationStaysWithinTheBudget`: 51 meetings with 100,000-char titles, 3,000 people, a 140 KB notes line; list (all pages), metadata, transcript (fewer than 10 pages), notes and search are each ≤ 64 KiB |
| S1 unfinished foreign export | The in-progress marker's `libraryID` must match, or the folder is refused (`BulkExport.swift`) | `unfinishedExportOfAnotherLibraryIsRefused` (and library A can still finish its own) |
| S2 notes-app syntax | Bulk Markdown body: `%`, `=`, `$`, `^` escaped; a zero-width space in `://`, in `www.` and before `@` (`MeetingFiles.inert`). Front matter keeps exact text. Documented in `docs/release/EXPORTS.md` | `notesAppSyntaxStaysText`; `read-export.py` now renders with linkify and catches a bare URL planted by hand; hostile seed gained bare URLs and Obsidian syntax (0 failures) |
| S3 harness | `record-under-load` checks every frame (each sample = previous + 1) and total frames against the time recorded until the stop request; reports the stop duration | Re-run: 0 discontinuities, frames within 0.1 s, 0 overruns (`Benchmarks/Results/access-t100/rul-*.json`) |
| S4 cursor scope | The request key includes a digest of the access scope | `cursorsAreBoundToScope` |
| N1 generation | `purgeMeeting`, every `publishTranscript` (including provisional) and `upsertJob` bump the content generation | covered by the existing cursor tests |
| N2 fsync | The temp file is synchronised before the rename | code |
| N3 README | Its hash is recorded in the manifest (`otherFiles`) and counted as Amaranth's own | `unfinishedExportOfAnotherLibraryIsRefused` checks `otherFiles` |
| N4 bound parameters | Not changed: fine for thousands of meetings; a temporary table would be needed far beyond. Listed under "Not verified / limits" | — |
| N5 transcript links | Transcript links need `word` (parse error otherwise) | `invalidAndMaliciousURLsAreRejectedBeforeAnyLookup` |
| N6 error entries | After a per-meeting error, the entry keeps the new hashes of files already written, and the old hashes only for the others | code |
| N7 link IDs | `SourceURL.string` is empty unless every part is valid; the Markdown export writes a plain label when there is no link | `oddIDsMakeNoLinks` |

Re-runs: full Milestone S test filter passes; eval: lexical 100%, paraphrase 25%, citations 1314/1314, adversarial
12/12; scale (206 meetings): search warm p95 313 ms, cold p95 198 ms; reader 0 failures on the 42-meeting and the
hostile exports.

## After verdict v2 (PASS)

- N-a: a journal with neither a marker nor a manifest (the marker removed by hand) is refused (test in
  `unfinishedExportOfAnotherLibraryIsRefused`).
- N-b: the qualification text now states the harness's 0.25 s tolerance next to the measured 0.1 s.
- N-c: recorded under "Not verified / limits" (title/person rows can fill the 1,000-row candidate pool).
