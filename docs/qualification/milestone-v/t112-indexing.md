# T112: resumable backfill and incremental local indexing (2026-11-06)

## Design

- `InferenceWorker/Core/ContextIndexingEngine` (ProcessingCore, app process): one bounded step = up to 32 chunk texts
  lacking a vector of the active encoder (newest meetings first), embedded by the worker (`.embed`, background) and
  published through the store's guarded writer (T111). The vectors table *is* the checkpoint (content-keyed), so a
  restart resumes with no separate state, repeated/late jobs are idempotent, and an edit or deletion while a batch is
  in the worker can't publish obsolete text (the hash is no longer held by a current chunk; tombstoning now also clears
  the meeting's chunks at once).
- Producer: remembered in UserDefaults; it counts only while it matches the installed encoder's revision + weights
  hash (`activeProducer`). A replaced model (or any producer change the worker reports) drops other producers' vectors
  and re-embeds everything — generations never mix.
- `App/Processing/ContextIndexer` (main actor) runs the loop and publishes `state` + `coverage`. New and edited
  meetings: chunks exist as soon as a final transcript is committed (provisional/live text is never chunked) and
  `kick()` runs on every library reload and processing change; notes are not waited for.
- Arbitration (`pauseReason`): no batch starts while recording, while any processing job is queued or running
  (transcription, diarization, notes), while an Ask is in progress, under memory pressure or when the Mac is hot; Record
  calls `yieldNow()` which cancels the running batch in the worker. In the worker, foreground (Ask) embeddings are
  admitted ahead of background batches (`ForegroundGate`, T110), so a question waits for at most one ≤ 32-text batch.
- Failures: texts the encoder rejects are counted per text (3 attempts, then skipped and reported as incomplete
  coverage); worker crashes/timeouts/transport errors are not the text's fault — exponential back-off 5 s → 5 min.
  Missing/corrupt encoder → `unavailable` (keyword lookup still works). Free disk < 500 MB → paused.

## Evidence

- Unit (`Tests/Jobs/ContextIndexingTests.swift`, fake worker): backfill completes and a restarted engine resumes
  without re-embedding; paused / encoder unavailable / low disk do no work; an edit and a deletion during a batch leave
  only current vectors and the edited chunk pending; a replaced encoder rebuilds without mixing; rejected texts are
  counted and skipped, transport errors aren't; `cancelCurrent()` stops a running batch in < 1 s.
- Packaged (`Amaranth --self-test embed-worker --model-dir ModelStore`, Debug app + XPC worker + real encoder from a
  temporary verified install): paused first with no vectors; cancel acknowledged in 0.06 s; 6 meetings / 180 chunks
  backfilled in 2.7 s; an edit re-indexed only its chunk; a new indexer after "restart" had 0 pending.
- Scale (`amaranth-bench ctx-scale --fill real`, `Benchmarks/Results/ctx-t112/scale-real.log`), 200 meetings × 1,000
  lines (200,000 lines), in-process encoder in batches of 64 (the worker uses 32):

| | |
|---|---|
| chunks / vectors | 25,493 / 25,493 (52 MB Float16) |
| full backfill | 385.5 s (6.4 min), 66 chunks/s, 8,239 tokens/s |
| database growth | 433 MB (v6) → 537 MB (chunks) → 592 MB (vectors, incl. WAL) |
| peak footprint (encoder + index work) | 786 MiB |
| vector search after backfill, k = 100: all / folder / week | p95 64 / 23 / 39 ms |

The backfill is background work: it only runs while nothing else does, so on a busy day it spreads over idle periods;
coverage is shown (T115) and partial coverage is reported in answers.
