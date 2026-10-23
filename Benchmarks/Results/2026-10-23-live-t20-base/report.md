# Live text delay on real recordings (T20, gate G4)

Settings: check every 2.00 s, per-source requests no, incremental processing on. Real-time replay of corpus excerpts through the real capture path and XPC worker.

**Pooled: median 2.21 s, p95 4.54 s over 4595 words. G4 (median ≤ 2 s, p95 ≤ 4 s): NOT met.**

| Meeting | Audio (s) | Words | Median (s) | p95 (s) | Segment wait (median) | Send wait (median / p95) | Worker (median / p95) | Mic vs final | System vs final | Loss / overruns | App / worker peak (MiB) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| corpus-test-youtopia-recording | 128 | 300 | 1.77 | 4.15 | 0.86 | 0.02 / 4.02 | 0.14 / 0.21 | 11.3% | 1.6% | 0 / 0 | 153 / 55 |
| corpus-work-mac-1 | 300 | 962 | 2.24 | 4.48 | 0.90 | 2.02 / 4.02 | 0.15 / 0.29 | 4.3% | 4.2% | 0 / 0 | 295 / 37 |
| corpus-work-mac-2 | 300 | 1228 | 2.18 | 4.29 | 0.88 | 2.02 / 4.02 | 0.15 / 0.17 | 2.2% | 4.5% | 0 / 0 | 300 / 39 |
| corpus-work-mac-3 | 300 | 1065 | 2.23 | 4.98 | 0.94 | 2.02 / 4.02 | 0.15 / 0.23 | 5.7% | 4.6% | 0 / 0 | 295 / 35 |
| corpus-work-mac-4 | 300 | 1040 | 2.33 | 4.98 | 0.86 | 2.02 / 4.02 | 0.14 / 0.23 | 3.5% | 3.3% | 0 / 0 | 290 / 36 |

- *Segment wait*: from the end of a word until the end of the 2 s capture segment holding it (session time). *Send wait*: from then until live text sent it to the worker (includes saving the segment). *Worker*: the request's round trip.
- *vs final*: word error rate of the live words against the meeting's final transcript over the excerpt. This is agreement, not accuracy: the final transcript is not a human reference.
