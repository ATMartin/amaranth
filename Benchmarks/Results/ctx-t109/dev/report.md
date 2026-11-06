# ctx-eval baseline — dev (55 questions)

Pipeline: shipped T53 FTS retriever + T54 answer prompt/checker; no date/person constraints.

| Category | n (with spans) | all-span Recall@10 | after prompt fitting | proxy OK |
|---|---|---|---|---|
| ALL | 42 | 23/42 (55%) | 23/42 (55%) | 41/55 (75%) |
| adversarial | 5 | 5/5 (100%) | 5/5 (100%) | 5/7 (71%) |
| ambiguous | 4 | 2/4 (50%) | 2/4 (50%) | 5/8 (62%) |
| changed_plan | 4 | 2/4 (50%) | 2/4 (50%) | 3/4 (75%) |
| commitments | 5 | 0/5 (0%) | 0/5 (0%) | 2/5 (40%) |
| cross_meeting | 8 | 1/8 (12%) | 1/8 (12%) | 5/8 (62%) |
| decision_status | 5 | 2/5 (40%) | 2/5 (40%) | 4/5 (80%) |
| dst_boundary | 3 | 0/3 (0%) | 0/3 (0%) | 1/3 (33%) |
| followup | 4 | 3/4 (75%) | 3/4 (75%) | 4/4 (100%) |
| incomplete_index | 1 | 1/1 (100%) | 1/1 (100%) | 1/1 (100%) |
| lexical | 6 | 6/6 (100%) | 6/6 (100%) | 6/6 (100%) |
| multipart | 3 | 0/3 (0%) | 0/3 (0%) | 3/3 (100%) |
| negation | 2 | 1/2 (50%) | 1/2 (50%) | 1/2 (50%) |
| notes_only | 1 | 0/1 (0%) | 0/1 (0%) | 0/1 (0%) |
| paraphrase | 17 | 6/17 (35%) | 6/17 (35%) | 11/17 (65%) |
| person_date | 11 | 3/11 (27%) | 3/11 (27%) | 8/12 (67%) |
| self | 4 | 0/4 (0%) | 0/4 (0%) | 2/5 (40%) |
| speaker_vs_mentioned | 7 | 6/7 (86%) | 6/7 (86%) | 7/9 (78%) |
| staffing | 5 | 1/5 (20%) | 1/5 (20%) | 4/5 (80%) |
| trimmed | 2 | 1/2 (50%) | 1/2 (50%) | 2/3 (67%) |
| unanswerable | 0 | – | – | 8/9 (89%) |

By expected behavior:

| behavior | n | Recall@10 (with spans) | proxy OK |
|---|---|---|---|
| answer | 35 | 18/35 (51%) | 26/35 (74%) |
| qualify | 5 | 3/5 (60%) | 2/5 (40%) |
| partial | 1 | 1/1 (100%) | 1/1 (100%) |
| clarify | 5 | 1/1 (100%) | 4/5 (80%) |
| abstain | 9 | – | 8/9 (89%) |

Retrieval p50 2 ms, max 20 ms. Retrieval+answer p50 2.0 s, max 3.3 s. Citations valid: 55/55 (100%).

Misses (all-span Recall@10): dev01 (0/5), dev02 (0/2), dev03 (1/2), dev05 (0/2), dev12 (1/3), dev19 (0/2), dev20 (0/2), dev24 (0/4), dev25 (0/2), dev26 (0/2), dev27 (0/2), dev28 (0/7), dev35 (0/1), dev40 (0/2), dev41 (1/3), dev42 (0/2), dev43 (0/2), dev45 (0/1), dev48 (0/2)
