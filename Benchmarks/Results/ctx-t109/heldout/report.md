# ctx-eval baseline — heldout (63 questions)

Pipeline: shipped T53 FTS retriever + T54 answer prompt/checker; no date/person constraints.

| Category | n (with spans) | all-span Recall@10 | after prompt fitting | proxy OK |
|---|---|---|---|---|
| ALL | 46 | 21/46 (46%) | 20/46 (43%) | 53/63 (84%) |
| adversarial | 3 | 1/3 (33%) | 1/3 (33%) | 3/6 (50%) |
| ambiguous | 2 | 2/2 (100%) | 2/2 (100%) | 4/5 (80%) |
| changed_plan | 6 | 3/6 (50%) | 3/6 (50%) | 6/6 (100%) |
| commitments | 6 | 1/6 (17%) | 1/6 (17%) | 5/6 (83%) |
| cross_meeting | 7 | 2/7 (29%) | 2/7 (29%) | 7/7 (100%) |
| decision_status | 3 | 0/3 (0%) | 0/3 (0%) | 3/3 (100%) |
| dst_boundary | 4 | 2/4 (50%) | 2/4 (50%) | 3/5 (60%) |
| followup | 7 | 3/7 (43%) | 2/7 (29%) | 7/7 (100%) |
| incomplete_index | 1 | 1/1 (100%) | 1/1 (100%) | 1/1 (100%) |
| multipart | 4 | 0/4 (0%) | 0/4 (0%) | 4/4 (100%) |
| negation | 2 | 1/2 (50%) | 1/2 (50%) | 2/2 (100%) |
| notes_only | 2 | 2/2 (100%) | 2/2 (100%) | 2/2 (100%) |
| paraphrase | 25 | 10/25 (40%) | 10/25 (40%) | 20/25 (80%) |
| person_date | 14 | 7/14 (50%) | 7/14 (50%) | 13/17 (76%) |
| self | 6 | 1/6 (17%) | 1/6 (17%) | 5/7 (71%) |
| speaker_vs_mentioned | 6 | 5/6 (83%) | 4/6 (67%) | 7/7 (100%) |
| staffing | 5 | 2/5 (40%) | 2/5 (40%) | 5/5 (100%) |
| trimmed | 0 | – | – | 2/2 (100%) |
| unanswerable | 0 | – | – | 10/12 (83%) |

By expected behavior:

| behavior | n | Recall@10 (with spans) | proxy OK |
|---|---|---|---|
| answer | 35 | 14/35 (40%) | 30/35 (86%) |
| qualify | 9 | 5/9 (56%) | 8/9 (89%) |
| partial | 1 | 1/1 (100%) | 1/1 (100%) |
| clarify | 4 | 1/1 (100%) | 3/4 (75%) |
| abstain | 14 | – | 11/14 (79%) |

Retrieval p50 8 ms, max 20 ms. Retrieval+answer p50 2.1 s, max 3.7 s. Citations valid: 63/63 (100%).

Misses (all-span Recall@10): h01 (0/2), h03 (1/2), h04 (0/2), h05 (1/3), h08 (3/7), h09 (1/2), h11 (1/3), h13 (1/2), h16 (2/3), h18 (0/2), h19 (2/3), h20 (0/2), h21 (0/3), h22 (0/7), h23 (1/3), h24 (2/4), h25 (1/3), h26 (1/4), h30 (0/1), h36 (0/1), h38 (1/2), h52 (1/2), h55 (0/2), h60 (1/2), h61 (1/2)
