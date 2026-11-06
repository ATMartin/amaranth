# T109 baseline: the shipped lexical + answer pipeline on the V fixtures (2026-11-06)

Pipeline as shipped before V: T53 FTS retriever (`Storage/Search/Retriever.swift`, OR-ed stemmed terms, ±2-line
windows, k = 12), T55 follow-up query concatenation, T54 answer prompt/checker on Qwen3-4B-Instruct-2507 Q4_K_M
(answer context 3,072 tokens). No date or person constraints. Each set seeded into its own isolated library with 40
filler meetings (`amaranth-bench ctx-eval baseline <set> <out> --answers <gguf>`). Raw rows and logs:
`Benchmarks/Results/ctx-t109/{dev,heldout}/`.

| Set | Questions with spans | all-span Recall@10 | after prompt fitting | citations valid | retrieval+answer p50 / max |
|---|---|---|---|---|---|
| dev | 42 | 23/42 (55 %) | 23/42 (55 %) | 55/55 | 2.0 s / 3.3 s |
| held-out | 46 | 21/46 (46 %) | 20/46 (43 %) | 63/63 | 2.1 s / 3.7 s |

Held-out by category (all-span Recall@10): paraphrase 10/25 (40 %), person/date 7/14 (50 %), multipart 0/4,
cross-meeting 2/7, follow-up 3/7, decision status 0/3, commitments 1/6, staffing 2/5, self 1/6; notes-only 2/2.
Every held-out miss: h01, h03, h04, h05, h08, h09, h11, h13, h16, h18, h19, h20, h21, h22, h23, h24, h25, h26, h30,
h36, h38, h52, h55, h60, h61 (see `heldout/report.md`).

The "proxy OK" column of the reports (refused ⇔ abstain expected) is mechanical, not a grade: the baseline answers
nearly everything with *something*, so it says little about correctness. Answers are kept in `rows.json` for the
same rubric grading as V's final run if a comparison is wanted; they were not graded here.

Not tuned on: the held-out questions were only run, never inspected for tuning; T110–T115 tune on `dev.json` only.

Hardware: Apple M2 Max 96 GB, macOS 27.0.1, release build; the user's Release app was running.
