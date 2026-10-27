# Data 0002: Retrieval for "ask anything" (T53)

Date: 2026-10-27 · Task: T53 · Status: Accepted.

## Decision

**Index (schema v4).** The FTS5 table gets two new columns:
- `speaker` (indexed): the shown speaker name(s) of each transcript line, with renames the user made since the last
  reconciliation applied.
- `evidence` (unindexed): the line's `TranscriptEvidence` (revision, segment, first and last word) as JSON. Notes
  items carry their transcript evidence the same way.

Two new row kinds: `speaker` (one row per user-named speaker) and `person` (one row per meeting person, T49).

The index is rewritten when people change (`setPeople`) and on a speaker rename (`appendEdit`), as well as on every
earlier trigger. Opening a v1–v3 library migrates it and rebuilds the index once. Older apps refuse v4.

**Keyword search** (the T52 panel) matches the `text` column only, so a speaker's name lists the speaker row, not every
line they said.

**`Retriever.search(question, in:)`** (Storage):
- Takes the question's words, drops English stop words and lightly stems them ("kitchens" → "kitchen*",
  "deciding" → "decid*").
- Runs them as quoted prefix terms, OR-ed, over `text` and `speaker`, ranked by bm25 (text weight 1.0, speaker 0.6).
- Reads 200 candidate rows.
- Builds transcript passages as ±2-line windows from adjacent rowids. Reindex inserts lines in transcript order, so
  no transcript decoding is needed. Windows whose context would overlap are merged, so no line appears twice.
- Turns each notes item into a passage of its own.
- A meeting whose title or people match the question gets a 15% boost.
- Returns the top k = 12 passages with their evidence refs.

Query expansion (prefix + light stemming) stays: the fixture ranking tests pass with it (fallback not needed).

## Measurements (M2 Max, macOS 27.0.1, Debug build of the Storage tests)

`swift test --filter RetrieverCorpus` uses a library built from the baseline-v0 corpus outputs (5 meetings with
transcripts and notes) and a copy of the work-Mac library. It runs 10 questions 3 times.

| Scope | Median | Max |
|---|---|---|
| Longest corpus meeting (working session, 71 min, 550 lines) | 0.6 ms | 8.4 ms |
| All corpus meetings | 1.2 ms | 11.2 ms |
| Work-Mac library copy (6 meetings, real) | 1.6 ms | 13.7 ms |

Target: < 50 ms. Opening the work-Mac copy migrates it v2 → v4 and rebuilds the index in 260 ms.
