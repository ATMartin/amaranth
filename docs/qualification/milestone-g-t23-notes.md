# T23 notes check and timing (2026-10-23)

Removing Topics from notes (`notes-v3`, decision record notes/0002, 2026-10-23 section). Release app, M2 Max,
`perf-suite run --suites corpus,notes --only <items> --compare Tests/Data/Recordings/baseline-v0`.

By user decision the 60-minute corpus timing was **not measured**; shorter corpus meetings and the notes checks were
run instead. Runs t23–t23c are intermediate (see "Iterations"); t23d is the shipped code.

## Notes checks (G5)

| Check | Bound | v2 (t18b/t19a) | v3 (t23d) |
|---|---|---|---|
| Evidence valid | 100% | 100% | 108/108 |
| Planted items, 60 min | all | 2/2 | 2/2 |
| Planted items, 120 min | all | 6/6 | not run (no runs over 60 min) |
| Injection resisted | 10/10 | 10/10 | 10/10 |
| Uncertain share | ≤ v0 + 5 points | 33.0% | 25.0% |

G5: **pass** (0 breaches; 3 corpus notes flags, expected because the item mix changed).

## Notes time (notes stage, seconds)

| Item | Audio | v2 (t18b / t19a) | v3 (t23d) | Change |
|---|---|---|---|---|
| corpus-hangout-ai-session | 36.5 min | 41.3 / 41.5 | 31.3 (cold worker) | −24% |
| corpus-youtopia-review-session | 22.5 min | 32.3 / 32.9 | 29.8 | −8% |
| corpus-test-youtopia-recording | 2.1 min | 10.9 / – | 11.2 | ≈ |
| notes-planted-60min (transcript only) | 60 min | 123.9 / 134.4 | 117.8 | −5% |

The first item of a run starts a cold worker (model load ≈ 6.5 s is inside its number). Removal alone (t23) was
faster still (25.0 / 27.6 s); the overview's transcript lines and verification add 2–6 s.

## Overview sentences kept

| Item | v2 | t23 (removal only) | v3 (t23d) |
|---|---|---|---|
| corpus-hangout-ai-session | 1 | **0** | 1 |
| corpus-youtopia-review-session | 1 | 1 | 1 |
| corpus-test-youtopia-recording | 1 | 1 | 3 |
| notes-planted-60min | 4 | 1 | 1 |

## Iterations

| Run | Change | Result |
|---|---|---|
| t23 | topics removed | G5 pass, but empty overview on a real meeting |
| t23b | overview reads transcript lines | injection 7/10 (breach); planted overview 0 (in-text citations failed grounding) |
| t23c | strip citations, skip AI-addressed lines, verify line-based sentences | injection 9/10 (breach) |
| t23d | agreements in the overview need a decision item | **pass**, injection 10/10 |

After the Milestone G validation (wider agreement-word guard), run t23e repeated t23d: G5 pass, evidence 108/108,
planted 2/2, injection 10/10, uncertain 25.0%; notes 31.4 / 30.0 / 11.2 / 118.1 s; overview counts unchanged.
