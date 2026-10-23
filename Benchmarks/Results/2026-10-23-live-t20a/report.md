# Live text delay on real recordings (T20, gate G4)

Settings: check every 0.25 s, per-source requests yes, incremental processing on. Real-time replay of corpus excerpts through the real capture path and XPC worker.

**Pooled: median 1.18 s, p95 3.13 s over 4931 words. G4 (median ≤ 2 s, p95 ≤ 4 s): met.**

| Meeting | Audio (s) | Words | Median (s) | p95 (s) | Segment wait (median) | Send wait (median / p95) | Worker (median / p95) | Mic vs final | System vs final | Loss / overruns | App / worker peak (MiB) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| corpus-test-youtopia-recording | 128 | 322 | 1.11 | 2.50 | 0.80 | 0.02 / 2.02 | 0.13 / 0.15 | 4.8% | 1.2% | 0 / 0 | 154 / 56 |
| corpus-work-mac-1 | 300 | 1019 | 1.20 | 3.52 | 0.86 | 0.02 / 2.02 | 0.14 / 0.17 | 4.3% | 3.9% | 0 / 0 | 294 / 40 |
| corpus-work-mac-2 | 300 | 1300 | 1.14 | 2.49 | 0.86 | 0.02 / 2.02 | 0.13 / 0.17 | 1.1% | 6.4% | 0 / 0 | 301 / 40 |
| corpus-work-mac-3 | 300 | 1157 | 1.24 | 3.78 | 0.86 | 0.02 / 2.02 | 0.14 / 0.17 | 3.5% | 4.4% | 0 / 0 | 297 / 37 |
| corpus-work-mac-4 | 300 | 1133 | 1.15 | 3.17 | 0.79 | 0.02 / 2.02 | 0.13 / 0.17 | 3.2% | 3.3% | 0 / 0 | 289 / 40 |

- *Segment wait*: from the end of a word until the end of the 2 s capture segment holding it (session time). *Send wait*: from then until live text sent it to the worker (includes saving the segment). *Worker*: the request's round trip.
- *vs final*: word error rate of the live words against the meeting's final transcript over the excerpt. This is agreement, not accuracy: the final transcript is not a human reference.
