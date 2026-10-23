# Live text delay on real recordings (T20, gate G4)

Settings: check every 0.25 s, per-source requests yes, incremental processing on. Real-time replay of corpus excerpts through the real capture path and XPC worker.

**Pooled: median 1.19 s, p95 3.40 s over 4946 words. G4 (median ≤ 2 s, p95 ≤ 4 s): met.**

| Meeting | Audio (s) | Words | Median (s) | p95 (s) | Segment wait (median) | Send wait (median / p95) | Worker (median / p95) | Mic vs final | System vs final | Loss / overruns | App / worker peak (MiB) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| corpus-test-youtopia-recording | 128 | 330 | 1.15 | 3.75 | 0.80 | 0.02 / 2.02 | 0.13 / 0.15 | 1.6% | 1.2% | 0 / 0 | 14 / 58 |
| corpus-work-mac-1 | 300 | 1031 | 1.20 | 3.55 | 0.86 | 0.02 / 2.02 | 0.14 / 0.17 | 4.3% | 4.2% | 0 / 0 | 13 / 42 |
| corpus-work-mac-2 | 300 | 1292 | 1.18 | 2.90 | 0.88 | 0.02 / 2.02 | 0.13 / 0.16 | 1.1% | 3.8% | 0 / 0 | 20 / 40 |
| corpus-work-mac-3 | 300 | 1154 | 1.23 | 3.64 | 0.84 | 0.02 / 2.02 | 0.13 / 0.16 | 3.8% | 4.6% | 0 / 0 | 23 / 37 |
| corpus-work-mac-4 | 300 | 1139 | 1.16 | 3.26 | 0.80 | 0.02 / 2.02 | 0.13 / 0.16 | 2.8% | 3.3% | 0 / 0 | 15 / 37 |

- *Segment wait*: from the end of a word until the end of the 2 s capture segment holding it (session time). *Send wait*: from then until live text sent it to the worker (includes saving the segment). *Worker*: the request's round trip.
- *vs final*: word error rate of the live words against the meeting's final transcript over the excerpt. This is agreement, not accuracy: the final transcript is not a human reference.
