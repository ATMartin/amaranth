# T111: versioned transcript chunks and local vector storage (2026-11-06)

Library schema **v7** (`Storage/Schema.swift`), code in `Storage/Search/ContextIndex.swift`.

## Design

- `context_chunks(meeting_id, ordinal, chunking, content_hash, text, spans, first_line, last_line, start_ns, revision_id)`:
  chunk-v1 chunks (`Domain/Search/Chunker.swift`) of the meeting's **current** transcript — the same decoded, edited
  revision and shown speaker names the search index uses. Rewritten by `MeetingStore.reindex`, i.e. inside every
  content-changing transaction (transcript publish, correction, line delete/restore, trims, speaker rename/reassign,
  retranscription, deletion). Spans carry the current first/last word IDs of each line for exact citations.
- `context_vectors(content_hash, producer, dims, vector)`: Float16 vectors keyed by chunk text hash + encoder producer
  id. Unchanged text keeps its vector across edits elsewhere; rewriting a chunk orphans its old hash and the vector is
  deleted in the same transaction.
- `context_meeting_state(meeting_id, generation, start_at)`: generation bumped on every rewrite (stale-result checks),
  meeting start (`clock.utcOrigin ?? createdAt`) for date filters. Folder comes from `meetings.folder_id` live, so moves
  re-scope immediately without re-embedding.
- `context_failures(content_hash, producer, attempts, error)`: failed embeddings; skipped after 3 attempts until cleared.
- **Guarded publication** (`publishContextVectors`): a vector is stored only if a current chunk holds that text and the
  vector is valid for the producer (dimension, finite, unit length). A job computed from text that has since been
  edited or deleted is dropped; incompatible dimensions/producers can't mix (search filters on producer + dims).
- **Scope-first exact search** (`vectorSearch`): SQL restricts to non-deleted meetings in the filter (meeting IDs,
  folder, start range) before any vector is read; rows stream (`SQLiteDB.forEach`) into a bounded top-k with vDSP dot
  products. No candidate cap: every meeting in scope is scanned.
- Deletion: tombstone removes the meeting from results at once (reindex clears its chunks); purge deletes chunks, state
  and vectors no other meeting's chunk holds. Audio-only deletion leaves transcript retrieval intact.
- Migration v6 → v7 chunks every meeting from current content in the migration transaction; it never embeds (the writer
  is not held for model work) and does not rewrite the search index.

## Tests (`Tests/DataLifecycle/ContextIndexTests.swift`)

Hidden words (trimmed, corrected-away, deleted) never in chunks after edits; spans resolve to current words; vectors of
edited-away text are deleted and can't be re-published; unchanged chunks keep vectors and only the edited chunk is
pending; generations bump; scope filters (meeting, folder, date, empty set) apply before scoring; wrong producer /
dimensions rejected; folder move re-scopes; audio-only deletion keeps retrieval; tombstone hides, purge removes chunks
and vectors (a vector shared with another meeting's identical text stays); failures counted and cleared; a v6 library
migrates with transcript and notes intact and chunks but no vectors.

## Scale (`amaranth-bench ctx-scale`, `Benchmarks/Results/ctx-t111/scale-random.txt`)

Library from `amaranth-access seed-scale 200 1000` (200 meetings × 1,000 lines = 200,000 lines), opened as v6:

| | |
|---|---|
| v6 → v7 migration (chunking 200 meetings) | 13.8 s (≈ 70 ms/meeting; a first version that also rebuilt the search index took 23.2 s) |
| chunks | 25,493 (chunk text 33 MB) |
| vectors (1,024-d Float16) | 25,493 = 52 MB |
| database | 433 MB → 537 MB after migration → 592 MB with vectors (incl. WAL) |
| exact vector search, k = 100, all 200 meetings | p50 63 ms, p95 66 ms (39 queries) |
| … one folder (67 meetings) | p50 19 ms, p95 20 ms |
| … one-week window | p50 39 ms, p95 39 ms |
| peak footprint during fill + search | 99 MiB |

Vectors here are random unit vectors (scan cost doesn't depend on values); real-encoder backfill throughput is T112's.
Exact scanning is far inside the 2 s retrieval budget at this scale, so no approximate index or vector extension is
adopted. 1,000 meetings would be ≈ 0.3 s by linear extrapolation (not measured).
