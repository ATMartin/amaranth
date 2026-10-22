# Decision records

| # | Decision | Status |
|---|----------|--------|
| [0001](0001-project-and-toolchain.md) | Project layout, toolchain, bundle identity, signing | Accepted (T01) |
| [0002](0002-domain-contracts.md) | Frozen domain contracts v1 | Accepted (T01) |
| [0003](0003-confirmed-scope.md) | User-confirmed scope, including live text promotion | Accepted (T01) |
| [0004](0004-milestones-and-performance-priority.md) | Milestone D reduced to T14; T12/T13 moved to final Milestone F; performance Milestone E; processing during recording; speed first for transcription | Accepted (2026-10-22) |
| [capture/0001](capture/0001-capture-design.md) | Core Audio process tap + HAL mic + C realtime ring + CAF segment writer | Accepted (T03); manual app/device matrix pending |
| [models/candidates](models/candidates.md) | Pinned package and model candidates (research) | Input to T02 |
| [models/0001](models/0001-model-selection.md) | Default model pack; 16 GB GO (projected), 8 GB unverified | Accepted, provisional (T02) |
| [models/0002](models/0002-model-pack-install.md) | Model pack install, verification, activation | Accepted (T04) |
| [storage/0001](storage/0001-storage-and-recovery.md) | Self-describing CAF segments, journal, SQLite index, launch recovery, disk/sleep policies | Accepted (T05) |
| [asr/0001](asr/0001-asr-pipeline.md) | Single-pass 2 s-context windows + under-yield guard; residual losses reported as `failed` coverage; two FluidAudio/Parakeet defects documented | Accepted (T06); real-call gates pending |
| [diarization/0001](diarization/0001-diarization-and-attribution.md) | Overlap-retaining offline diarization, blockwise > 1 h, intersection attribution, reversible echo, rebased edits | Accepted (T07); DER gate not met on clean AMI |
| [processing/0001](processing/0001-orchestration.md) | App-side scheduler, XPC worker, content-keyed DAG, leases, pressure suspension, stale-result guards | Accepted (T08) |
| [notes/0001](notes/0001-evidence-backed-notes.md) | Local notes: line-numbered transcript, chunked extraction, deterministic evidence checks, model verification, computed limitations | Accepted (T09); human evaluation pending |
| [notes/0002](notes/0002-faster-notes.md) | Batched notes generation (16 sequences, shared KV), compact JSON (`notes-v2`), notes yield to transcription and resume; scheduler idle-spin fix; draft model and Qwen3-1.7B measured, not used | Accepted (T18) |
| [ui/0001](ui/0001-recording-and-review-ui.md) | SwiftUI recorder/library/review UI, menu bar, quit guard, Presentation module | Accepted (T10); hands-on pass pending |
| [data/0001](data/0001-search-export-deletion.md) | FTS5 search, TXT/MD/JSON export, audio-only and full deletion with byte-level guarantees | Accepted (T11) |
| [live/0001](live/0001-live-text.md) | Live provisional text from committed audio, stateless worker passes, under-yield guard, pause under pressure | Accepted (T14); real calls/base M2 unverified |

Qualification evidence: `docs/qualification/` (capture matrix, manual checklist, raw JSONL in `evidence/`).
Benchmark results: `Benchmarks/Results/<run>/report.json` (+ `raw/`; generated inputs are gitignored).
