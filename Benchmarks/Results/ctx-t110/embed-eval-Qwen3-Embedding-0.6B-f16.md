# embed-eval Qwen3-Embedding-0.6B-f16.gguf on dev

400 chunks; documents embedded in 5.1 s (79 chunks/s); all-span Recall@10 counts (questions with labeled spans).

### 1024 dimensions

| category | n | fts | vector | hybrid | fts+date | vector+date | hybrid+date |
|---|---|---|---|---|---|---|---|
| ALL | 41 | 22 | 26 | 30 | 24 | 31 | 33 |
| adversarial | 5 | 5 | 5 | 5 | 5 | 5 | 5 |
| ambiguous | 4 | 1 | 2 | 2 | 1 | 3 | 3 |
| changed_plan | 4 | 2 | 1 | 4 | 3 | 3 | 4 |
| commitments | 5 | 0 | 3 | 3 | 0 | 5 | 5 |
| cross_meeting | 8 | 1 | 3 | 5 | 2 | 5 | 6 |
| decision_status | 5 | 1 | 2 | 3 | 1 | 2 | 3 |
| dst_boundary | 3 | 0 | 1 | 1 | 1 | 3 | 2 |
| followup | 4 | 2 | 1 | 2 | 2 | 2 | 2 |
| incomplete_index | 1 | 1 | 1 | 1 | 1 | 1 | 1 |
| lexical | 6 | 6 | 6 | 6 | 6 | 6 | 6 |
| multipart | 3 | 0 | 1 | 1 | 0 | 2 | 2 |
| negation | 2 | 1 | 0 | 1 | 1 | 0 | 1 |
| paraphrase | 16 | 7 | 10 | 12 | 9 | 12 | 13 |
| person_date | 11 | 3 | 5 | 6 | 5 | 10 | 9 |
| self | 4 | 0 | 2 | 2 | 0 | 4 | 4 |
| speaker_vs_mentioned | 7 | 6 | 6 | 6 | 6 | 6 | 6 |
| staffing | 5 | 1 | 1 | 1 | 1 | 1 | 1 |
| trimmed | 2 | 1 | 0 | 2 | 1 | 0 | 2 |

### 512 dimensions

| category | n | fts | vector | hybrid | fts+date | vector+date | hybrid+date |
|---|---|---|---|---|---|---|---|
| ALL | 41 | 22 | 26 | 25 | 24 | 29 | 31 |
| adversarial | 5 | 5 | 4 | 5 | 5 | 4 | 5 |
| ambiguous | 4 | 1 | 2 | 2 | 1 | 3 | 3 |
| changed_plan | 4 | 2 | 1 | 2 | 3 | 1 | 4 |
| commitments | 5 | 0 | 3 | 2 | 0 | 5 | 5 |
| cross_meeting | 8 | 1 | 3 | 2 | 2 | 4 | 5 |
| decision_status | 5 | 1 | 1 | 2 | 1 | 1 | 2 |
| dst_boundary | 3 | 0 | 1 | 0 | 1 | 2 | 2 |
| followup | 4 | 2 | 1 | 1 | 2 | 1 | 2 |
| incomplete_index | 1 | 1 | 1 | 1 | 1 | 1 | 1 |
| lexical | 6 | 6 | 6 | 6 | 6 | 6 | 6 |
| multipart | 3 | 0 | 1 | 0 | 0 | 2 | 2 |
| negation | 2 | 1 | 1 | 1 | 1 | 1 | 1 |
| paraphrase | 16 | 7 | 10 | 9 | 9 | 11 | 11 |
| person_date | 11 | 3 | 5 | 3 | 5 | 8 | 9 |
| self | 4 | 0 | 2 | 2 | 0 | 4 | 4 |
| speaker_vs_mentioned | 7 | 6 | 6 | 6 | 6 | 6 | 6 |
| staffing | 5 | 1 | 1 | 1 | 1 | 1 | 1 |
| trimmed | 2 | 1 | 1 | 1 | 1 | 1 | 1 |

### 256 dimensions

| category | n | fts | vector | hybrid | fts+date | vector+date | hybrid+date |
|---|---|---|---|---|---|---|---|
| ALL | 41 | 22 | 23 | 23 | 24 | 26 | 29 |
| adversarial | 5 | 5 | 4 | 4 | 5 | 4 | 4 |
| ambiguous | 4 | 1 | 2 | 2 | 1 | 3 | 3 |
| changed_plan | 4 | 2 | 1 | 1 | 3 | 1 | 3 |
| commitments | 5 | 0 | 3 | 2 | 0 | 5 | 5 |
| cross_meeting | 8 | 1 | 2 | 1 | 2 | 3 | 4 |
| decision_status | 5 | 1 | 0 | 0 | 1 | 0 | 0 |
| dst_boundary | 3 | 0 | 1 | 0 | 1 | 2 | 2 |
| followup | 4 | 2 | 1 | 1 | 2 | 1 | 2 |
| incomplete_index | 1 | 1 | 1 | 1 | 1 | 1 | 1 |
| lexical | 6 | 6 | 5 | 6 | 6 | 5 | 6 |
| multipart | 3 | 0 | 1 | 0 | 0 | 2 | 2 |
| negation | 2 | 1 | 0 | 0 | 1 | 0 | 0 |
| paraphrase | 16 | 7 | 9 | 9 | 9 | 10 | 11 |
| person_date | 11 | 3 | 5 | 3 | 5 | 8 | 9 |
| self | 4 | 0 | 2 | 2 | 0 | 4 | 4 |
| speaker_vs_mentioned | 7 | 6 | 6 | 6 | 6 | 6 | 6 |
| staffing | 5 | 1 | 1 | 1 | 1 | 1 | 1 |
| trimmed | 2 | 1 | 1 | 1 | 1 | 1 | 1 |
