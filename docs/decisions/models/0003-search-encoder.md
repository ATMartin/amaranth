# Models 0003: contextual search encoder (T110, 2026-11-06)

**Decision:** Qwen3-Embedding-0.6B, official Qwen GGUF **Q8_0**, 1,024 dimensions, last-token pooling, through the app's
pinned llama.cpp **b11669** (no runtime change). Shipped as manifest `qwen3-embedding-0.6b-q8_0` in model pack
`amaranth-default-16gb` **0.1.2** (the 0.1.1 manifests unchanged + the encoder). Chunks: chunk-v1, target 120 /
max 200 encoder tokens, 1 line overlap.

## Pins

| | |
|---|---|
| Upstream | Qwen/Qwen3-Embedding-0.6B @ 97b0c614be4d77ee51c0cef4e5f07c00f9eb65b3 (model card: Apache-2.0) |
| Artifact | Qwen/Qwen3-Embedding-0.6B-GGUF @ 370f27d7550e0def9b39c1f16d3fbaa13aa67728, `Qwen3-Embedding-0.6B-Q8_0.gguf` |
| Weights sha256 | 06507c7b42688469c4e7298b0a1e16deff06caf291cf0a5b278c308249c3e439 (639,150,592 bytes; matches the HF LFS oid) |
| Notice | `LICENSE` from Qwen/Qwen3-0.6B-Base @ da87bfb6 (the GGUF repo ships none; git blob sha1 checked), `README.md` model card (blob sha1 checked) |
| Download | 639.2 MB (pack total 3.64 GB; an upgrade from 0.1.1 fetches only the encoder — identical files are hash-verified and APFS-cloned from the installed pack, `ModelInstaller.reusableFile`) |
| Producer identity | `EncoderProducer`: family, manifest, revision, weights sha256, quantization, dimensions, pooling (`last-token+endoftext`), normalization (`l2-after-mrl-truncation`), query instruction, document prefix (none), chunking version, runtime — any change gives a new `id` and a versioned rebuild |

## Recipe (from the model card, implemented in `Notes/Engine/LlamaEmbedder.swift`)

- Query: `Instruct: Given a question about past work meetings, retrieve transcript passages where the answer was discussed\nQuery:<question>`; documents: no prefix.
- Input ends with `<|endoftext|>` (the GGUF tokenizer does not add it; added explicitly). User text never parses special tokens.
- Context `embeddings = true`, `pooling_type = LAST`, several sequences packed per batch (n_batch = n_ubatch = 4,096 tokens, ≤ 32 sequences); output L2-normalized; non-finite/zero/wrong-dimension vectors rejected (`VectorCheck`).
- Packing several sequences into one batch gives the same vector as embedding alone (cosine > 0.999, `EmbedderTests`).

## Measurements (M2 Max 96 GB, macOS 27.0.1, release build, user's app running)

| | Q8_0 | f16 |
|---|---|---|
| load (file cache warm) | 0.22 s | 0.24 s |
| footprint after load / after a 256-doc batch | +559 MB / 738 MB | +556 MB / 736 MB |
| document throughput (290-token docs, packed) | 8,553 tokens/s (29.5 docs/s) | 9,216 tokens/s |
| query latency p50 / p95 | 17.3 / 17.6 ms | 17.0 / 17.5 ms |
| packaged XPC worker, cold (worker launch + verified load + first batch) | 0.79 s | – |
| packaged XPC worker, warm query | 17 ms | – |

Backfill estimate at the scale fixture (200 meetings × 1,000 lines ≈ 2.4 M encoder tokens in ~25 k chunks at 120/200):
≈ 5 min of encoder time, to be measured in T112.

Dev-set retrieval (`amaranth-bench embed-eval`, dev.json only; all-span hits out of 41 questions with spans; each
mode gets the same budget of the best-ranked chunks up to 100 distinct lines; `+date` = oracle meeting-date filter):

| Variant | FTS | vector | hybrid (RRF k = 60) | FTS+date | vector+date | hybrid+date |
|---|---|---|---|---|---|---|
| Q8_0, 1024 d, chunks 120/200 (**chosen**) | 22 | 26 | 30 | 24 | 31 | **33** |
| Q8_0, 512 d | 22 | 26 | 25 | 24 | 29 | 31 |
| Q8_0, 256 d | 22 | 23 | 23 | 24 | 26 | 29 |
| f16, 1024 d | 22 | 26 | 30 | 24 | 31 | 33 |
| Q8_0, 1024 d, chunks 60/100 | 22 | 29 | 28 | 24 | 32 | 30 |
| Q8_0, 1024 d, chunks 300/400 (spec's initial) | 26 | 25 | 28 | 29 | 27 | 30 |

Reading: f16 = Q8_0 (so Q8_0, half the disk). Truncating dimensions costs recall; 1,024 kept (4 KiB/vector as
Float32, 2 KiB as Float16 → ~50–100 MB at 25 k chunks). Smaller chunks help the vector side; FTS-mapped chunks favor
large ones; 120/200 gives the best fused result. Hybrid beats either list alone; the date filter (T113) adds more.
Paraphrase 13/16 and person/date 9–10/11 at best here: **query variants from the planner (T113) and context expansion /
coverage (T114) are still needed to reach the gates.** No leaderboard number is used as evidence of app quality.

Not compared: a smaller encoder (not needed: the 0.6B passes the runtime/latency/memory budget with room; quality gaps
are retrieval-workflow gaps, visible on both quantizations). A dedicated reranker was not adopted (T114 decides with
evidence).

## Load/unload policy and the 15 s budget

The encoder stays resident in the worker beside the ASR models or the notes LLM (≈ 0.75 GB including its batch
context); `unloadAll` (memory pressure, worker exit) releases it. Foreground (Ask) embedding requests are admitted ahead
of background indexing batches (`ForegroundGate`): a foreground request waits for at most one running batch (≤ 64 texts,
≈ 0.5 s). Within one Ask attempt the cold costs are: encoder ≤ 0.8 s cold, notes LLM ≈ 0.5 s load (N, file cache warm;
3.6 GB incl. its context) — the answer-path budget is verified end to end in T115/T116. A real cold disk read of the
3.1 GB of GGUFs would add ~1–2 s; T116 measures process-cold runs.
