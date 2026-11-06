# ctx-eval retrieve — dev (55 questions)

All-span recall (every required piece has a line in the passages).

| category | n | top 10 | final set |
|---|---|---|---|
| ALL | 42 | 35/42 (83%) | 37/42 (88%) |
| adversarial | 5 | 5/5 (100%) | 5/5 (100%) |
| ambiguous | 4 | 3/4 (75%) | 4/4 (100%) |
| changed_plan | 4 | 4/4 (100%) | 4/4 (100%) |
| commitments | 5 | 5/5 (100%) | 5/5 (100%) |
| cross_meeting | 8 | 6/8 (75%) | 6/8 (75%) |
| decision_status | 5 | 4/5 (80%) | 4/5 (80%) |
| dst_boundary | 3 | 3/3 (100%) | 3/3 (100%) |
| followup | 4 | 3/4 (75%) | 3/4 (75%) |
| incomplete_index | 1 | 1/1 (100%) | 1/1 (100%) |
| lexical | 6 | 6/6 (100%) | 6/6 (100%) |
| multipart | 3 | 2/3 (67%) | 2/3 (67%) |
| negation | 2 | 1/2 (50%) | 1/2 (50%) |
| notes_only | 1 | 0/1 (0%) | 0/1 (0%) |
| paraphrase | 17 | 14/17 (82%) | 15/17 (88%) |
| person_date | 11 | 10/11 (91%) | 10/11 (91%) |
| self | 4 | 4/4 (100%) | 4/4 (100%) |
| speaker_vs_mentioned | 7 | 6/7 (86%) | 6/7 (86%) |
| staffing | 5 | 1/5 (20%) | 1/5 (20%) |
| trimmed | 2 | 1/2 (50%) | 2/2 (100%) |
| unanswerable | 0 | – | – |

Retrieval after planning p50 0.06 s p95 0.08 s; planning p50 1.13 s p95 1.81 s; total p50 1.19 s p95 1.89 s.

Misses (top 10): dev01 (4/5), dev02 (1/2), dev03 (1/2), dev05 (1/2), dev08 (1/2), dev45 (0/1), dev48 (0/2)
