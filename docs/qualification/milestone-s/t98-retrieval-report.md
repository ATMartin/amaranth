# T98: bounded retrieval report (2026-11-03)

Operations `list_meetings`, `search_meetings` and `get_meeting` (`MeetingAccess/Retrieval.swift`), on the snapshot
contract from T97. Synthetic, isolated libraries only; no real meeting text.

## Retrieval quality (labeled question set)

`Benchmarks/AccessEval/questions.json`: 33 lexical/name/acronym/filter/notes/edited/cross-meeting questions, 8 paraphrases,
12 unanswerable/adversarial cases, over the library from `amaranth-access seed-eval` (11 fact meetings with three planted
lines each among 120 filler lines, a notes-only meeting, generated and user notes, a corrected price, a deleted line,
a deleted meeting, 30 filler meetings with one prompt-injection line).

| Measure | Result | Gate |
|---|---|---|
| Lexical/name/filter/notes Recall@10 | **100%** (33/33 questions, every labeled source in the top 10; each question has one at rank 1 or 2) | ≥ 85%: **pass** |
| Paraphrase Recall@10 | **25%** (2/8) | reported separately |
| Citation resolution (every returned line) | **1314/1314** resolve to current content (1257/1257 before the M1 fix) | 100%: **pass** |
| Unanswerable/adversarial checks | **12/12** | all |

Paraphrase misses (lexical search matches words, not meaning): p01 retreat/attendee spend vs "offsite budget per person";
p02 "candidate" vs "offer … staff engineer"; p03 "revoke the exposed credential" vs "leaked API key was rotated"; p04
"content delivery providers" vs "CDN"; p07 "color/designer" vs "accent/Fay"; p08 "yearly recurring revenue" vs "ARR".
Hits: p05 (rank 6, via "migration" filler), p06 (rank 2, via the generated note). This is the measured gap a local
hybrid (FTS + embeddings) proposal would have to close; it is **not** proposed here. The question set was not tuned to
the results; one adversarial check (u06) was re-specified after the first run because it was wrong, not because
retrieval changed (see the file's `about`).

Unanswerable questions (u01, u08, u12) return either nothing or the best lexical matches; search never claims an answer
exists or that results are complete. Every search response carries these limitations: matches words not meaning,
ranked passages not a complete list (use list + get for exhaustive questions), score is not a confidence; with a
participant filter, that being listed is not having said a passage. Corrected-away text ("nineteen"), the deleted
"Initech" line and the deleted meeting never come back; filters and meeting IDs exclude meetings before ranking
(u04, u05, u09, u10); FTS syntax in queries stays text (u07).

Full table: `Benchmarks/Results/access-t98/report.md` (+ `results.json`).

## Scale and latency

Library: **200 meetings × 1,000 lines (200,000 transcript lines, 416 MB)** from `amaranth-access seed-scale`, with people,
a folder and one notes line per meeting. The spec's 1,000-meeting / ~1-million-line library was **not measured (user
decision 2026-11-03: 200-meeting library)**. Release build of `amaranth-access`; cold = 25 fresh processes × one operation
of each kind (new store, nothing cached by the app; the OS file cache is warm); warm = 104 operations in one process,
first of each kind dropped. Operations: list (50 rows, every 8th with a participant filter), search (20 passages, 10
rotating queries), get_meeting metadata, get_meeting transcript first page. Times in ms.

meetings 200; peak footprint MiB: cold max 30, warm 59; store open p50 1.3 ms
| operation | cold n | cold p50 | cold p95 | warm n | warm p50 | warm p95 |
|---|---|---|---|---|---|---|
| list | 25 | 4.2 | 4.8 | 25 | 3.4 | 3.9 |
| search | 25 | 95.5 | 100.0 | 25 | 100.0 | 201.3 |
| getMetadata | 25 | 83.2 | 86.0 | 25 | 80.4 | 81.6 |
| getTranscript | 25 | 81.0 | 85.4 | 25 | 81.4 | 85.4 |
| all | 100 | 82.0 | 99.4 | 100 | 80.4 | 155.3 |
max cold 126.2 ms, max warm 212.9 ms

Gate (spec: warm p95 ≤ 1 s, cold ≤ 3 s, no model loads): **pass at 200 meetings**. No model is loaded: the
`MeetingAccess` module and `amaranth-access` link only Domain and Storage. get_meeting reads and decodes the meeting's
stored transcript (≈ 77 ms of its ≈ 80 ms for 1,000 lines); search builds citations from the search index instead
(an earlier version that built snapshots per result meeting measured search p95 ≈ 1.7 s and missed the gate).
Extrapolation, not a measurement: FTS cost grows with the index, so 1,000 meetings could put search near 0.5 s.

Hardware/OS: Apple M2 Max, 96 GB, macOS 27.0.1 (26A434), Swift 6.4.2, system SQLite 3.54.0; machine load average ≈ 2.5
during the runs (the user's Release app was running).

## After the validator's fixes (verdict v1, 2026-11-03)

M1: search pages were ranked from a candidate pool that grew with the page number, so deep pages repeated or reordered
passages. Every request now ranks once with fixed parameters (k = 100 passages, 1,000 FTS candidates) and pages are
slices of that list (test: 12 meetings × 20 matching lines paged to the end, no repeats, ranks 1…n). Re-run on the same
library (206 meetings: the six recordings from T100's capture runs were added to it); recall unchanged, citations
1314/1314:

meetings 206; peak footprint MiB: cold max 33, warm 54; store open p50 1.3 ms
| operation | cold n | cold p50 | cold p95 | warm n | warm p50 | warm p95 |
|---|---|---|---|---|---|---|
| list | 25 | 5.5 | 6.3 | 25 | 3.8 | 4.2 |
| search | 25 | 191.6 | 197.8 | 25 | 199.0 | 313.3 |
| getMetadata | 25 | 85.3 | 88.4 | 25 | 80.7 | 82.9 |
| getTranscript | 25 | 83.6 | 86.2 | 25 | 81.2 | 84.6 |
| all | 100 | 84.1 | 195.5 | 100 | 81.0 | 264.8 |
max cold 201.6 ms, max warm 316.1 ms

Search p95 rose from 201 to 313 ms warm (more candidates per request), still well inside the 1 s gate. M2: list and
metadata projections cap titles (512 characters), names (100) and lists (50); list pages shrink to fit 64 KiB; search
lines over 1,000 characters are shortened and marked. Every operation is tested at ≤ 64 KiB with 100,000-character
titles, 3,000 people and a 140 KB notes line.

## Behaviour covered by tests (`Tests/DataLifecycle/RetrievalTests.swift`)

Filter intersections (folder × participant × meeting IDs; inclusive start/exclusive end; first-name and accent-insensitive
participant match); scope applied to list/search/get, including guessed IDs (unavailable) and context windows next to an
out-of-scope meeting in the index; folder scope following moves; deleted meetings; stable ordering of tied starts and
tied ranks, paging with no repeats; cursors bound to operation/query (refused otherwise) and to the content generation
(restart_required after a change); get_meeting cursors bound to the meeting fingerprint; expected-fingerprint reads
(changed); oversized notes lines in fragments that reassemble exactly; a 3,000-line transcript paged with every response
≤ 64 KiB; input ceilings; malicious FTS input; cancellation and deadline.

## Commands

    swift build -c release --product amaranth-access --scratch-path .build-check
    BIN=.build-check/out/Products/Release/amaranth-access
    $BIN seed-eval <scratch>/eval-lib && $BIN eval <scratch>/eval-lib Benchmarks/AccessEval/questions.json <scratch>/eval-out
    $BIN seed-scale <scratch>/scale-lib 200 1000          # 63 s
    for i in $(seq 1 25); do $BIN scale <scratch>/scale-lib 4 cold-$i; done > scale.jsonl
    $BIN scale <scratch>/scale-lib 104 warm >> scale.jsonl
    python3 Benchmarks/AccessEval/scale-summary.py scale.jsonl
    swift test --scratch-path .build-check --filter "RetrievalTests|MeetingSnapshotTests|CitationURLTests|ExternalSnapshotContract"
