# Live 0002: Lower live text delay; delay samples per meeting; flush at Stop (T20)

Date: 2026-10-23 · Task: T20 (docs/milestone-e-performance-plan.md) · Status: Accepted (user scope decisions
2026-10-23: capture segments stay 2 s, live text reads saved segments only, "real recordings" means real-time replay of
corpus excerpts, live word error rate may rise by at most 1 point, final transcripts unchanged). Amends live/0001.

## Context

G4 asks for live text delay of **median ≤ 2 s and p95 ≤ 4 s on real recordings**. Before T20, the delay had only been
measured on a synthetic replay (2.18 s / 4.99 s), and nothing recorded it during real meetings. Delay is measured
per word, from the end of the spoken word to its first appearance on screen (stable or tentative).

Before T20, live text worked like this (live/0001):
- every 2 s, a timer sent **one** request to the worker;
- the source furthest behind went first, so with two active sources each source was served every other tick;
- a word could only be read once the 2 s capture segment holding it was saved.

The user ruled out the two levers that change capture: shorter (1 s) segments, and reading the segment still being
written. Both would cut the wait for the segment to be saved, about 1 s at the median.

## Measuring where the time goes

Each delay sample is now split into three parts that sum to the delay (`LiveTranscriptState.LatencySample`):
- **segment wait**: from the end of the word until the end of the 2 s segment holding it (session time; the
  segment can be read only after that);
- **send wait**: from then until live text sent a request carrying it (this includes the few milliseconds the
  writer takes to save the segment);
- **worker**: that request's round trip.

Baseline on real recordings (v1 settings, `Benchmarks/Results/2026-10-23-live-t20-base/`), medians per meeting:
segment wait 0.86–0.94 s, **send wait 2.02 s** (p95 4.02 s), worker 0.14–0.15 s (p95 0.17–0.29 s). The send wait was
the source's turn: with both people talking, mic and system audio alternated for the single request. Only the
2-minute meeting, where the second source was mostly quiet, had a send wait near 0. So the floor with 2 s segments
is about 1 s (segment wait) plus about 0.15 s (worker), plus the words that only appear one pass later because they
end right at the edge of the saved audio.

## Decision

1. **One request in flight per source** instead of one overall (`LiveTextModel.perSource`). The worker still has
   one live decoder, so requests queue there for at most about 0.15 s. They never wait for the other source's 2 s turn.
2. **A 0.25 s check instead of a 2 s tick** (`LiveTextModel.interval`). Each check first asks the session for the
   newest saved time per source (`RecordingSession.lastCommitted`, no copy), and takes a snapshot only when a source
   has at least 0.5 s of new audio. In the replays the 2 s timer happened to fire just after each segment was saved,
   so a shorter check gained little there (synthetic: 1.32 s / 3.06 s at 2 s vs 1.30 s / 3.42 s at 0.25 s). On a real
   Mac the timer drifts against the audio clock, so a 2 s tick waits about 1 s on average. The 0.25 s check bounds
   that wait at 0.25 s and costs a lock read per source.
3. **Durable segments stay the only input** (live/0001 rule), and segments stay 2 s (user decision).
4. **Delay samples per meeting.** Every 30 s and at Stop, live text writes `live-latency.json` into the meeting's
   folder (`LiveLatencyLog`: per word, the source, the end time, the delay and its breakdown, plus median/p95 per
   source). It holds metrics only, never text, so real meetings can be measured afterwards. It is deleted with the
   meeting folder.
5. **Flush at Stop (tracked item 23).** Before, Stop published whatever tentative words existed, and the audio after
   the last pass (up to one tick, plus the last partial segment) was never decoded. Now `LiveTextModel.finish`:
   - lets in-flight passes land;
   - sends one `final` request per source with all remaining saved audio, including the last partial segment;
   - the worker pads the end with 1 s of silence, so the last word is decoded whole, and settles every word;
   - the result is published as the provisional revision.

   Live text detaches from the recording before the flush awaits anything, and the flush works on its own copy of
   the state, so a new recording can start at once (back to back). Replies to passes still in flight are dropped;
   the flush re-decodes from the same stable points. In-flight bookkeeping is per recording (a generation counter),
   so an old recording's late reply never affects the new one. The flush also runs if live text was paused for
   pressure at Stop, because it is a single bounded pass after recording has ended. It is bounded to 10 s, and it
   records no delay samples (those words appear after Stop). The final transcript replaces the provisional one as
   before.

## Results (Release, M2 Max)

**Real recordings** (`amaranth-bench live-suite run`, `--self-test live-replay`): 5-minute excerpts of 4 work-Mac
meetings (starting 5 min in) plus the whole 2-minute first Amaranth meeting. All have separate mic and system tracks.
They are replayed in real time through the real capture path and XPC worker, with incremental processing running as
in the app. 22 minutes of audio per run.

| Run | Settings | Words | Median (s) | p95 (s) | Per meeting: median / p95 (s) | Send wait median / p95 (s) |
|---|---|---|---|---|---|---|
| `2026-10-23-live-t20-base` | v1: 2 s tick, one request | 4,595 | 2.21 | **4.54** | 1.77–2.33 / 4.15–4.98 | 2.02 / 4.02 (2-min meeting 0.02) |
| `2026-10-23-live-t20a` | T20 | 4,931 | 1.18 | 3.13 | 1.11–1.24 / 2.49–3.78 | 0.02 / 2.02 |
| **`2026-10-23-live-t20b`** (final build) | **T20** | 4,946 | **1.19** | **3.40** | 1.15–1.23 / 2.90–3.75 | 0.02 / 2.02 |

- App peak footprint during the final replays was 13–23 MiB and the worker's 37–58 MiB. The t20a and baseline
  runs report about 290 MiB for the app, but that was the replay harness holding each excerpt in memory; it has
  since been changed to write excerpts piece by piece.

- The send-wait p95 of about 2 s is words that end at the edge of the saved audio and first appear in the next pass,
  one segment later. Segment wait and worker time are unchanged.
- **Live text vs the final transcript** (word error rate of what live text shows against each meeting's final
  transcript; agreement, not accuracy). During the replay, incremental processing replaces live words with
  final-pipeline words about 30–40 s behind, as in the app. So these figures partly compare final words with final
  words, and they are not a measure of the provisional words alone. The same holds for the before and after runs.
  The live word error rate bound rests on the synthetic runs below. Figures: mic 1.1–4.3% (mean 2.7%), system 1.2–4.6% (mean 3.4%) in t20b. Before T20: mic 2.2–11.3% (mean 5.4%), system
  1.6–4.6% (mean 3.6%).
- Capture: 0 missing-audio events and 0 ring overruns in every replay.

**Synthetic** (`--self-test live-latency`, LibriSpeech mic + AMI system audio, the replay with a true reference),
evidence `docs/qualification/evidence/2026-10-23/t20-live-latency*.jsonl`:

| Settings | Runs | Median (s) | p95 (s) | Provisional mic WER |
|---|---|---|---|---|
| v1: 2 s tick, one request | 3 | 2.12–2.20 | 4.37–4.89 | 3.0%, 2.4%, 3.0% (mean 2.8%) |
| 2 s tick, one request per source | 1 | 1.32 | 3.06 | 3.0% |

Evidence: v1 `t20-live-latency-v1-settings`, `-rep-2-no-a`, `-rep-2-no-b`; per-source at 2 s `-syn-2-yes`; T20
`t20-live-latency`, `-syn-0.25-yes`, `-rep-0.25-yes-a`, `-rep-0.25-yes-b`, `-after-review` (the last on the final
code, after the review fixes below). Synthetic replay has no free-running
timer drift, so the effect of the 0.25 s check alone is not visible here (one run each: 1.32 / 3.06 s at 2 s vs
1.30 / 3.42 s at 0.25 s). The gain measured here comes from per-source requests.
| **T20: 0.25 s check, one request per source** | 5 | 1.28–1.33 | 3.08–3.42 | 4.2%, 3.0%, 3.0%, 1.8%, 3.0% (mean 3.0%) |

- Live word error rate: +0.2 points on average, inside the +1.0 point allowance. Single runs vary by ±1.2 points
  (about 4 words of the 10 LibriSpeech utterances).
- The flush adds the last words to every run. In the unit test, 54 of 54 words reach the provisional transcript,
  against 42 without the flush.
- **live-pressure** (15 s simulated thermal pause): paused and caught up to 124 of 124 s, 0 loss. Median 1.38 s; p95
  9.13 s includes the pause by design.
- **live-load** (G6: incremental processing plus every stage of an earlier 20-minute meeting alongside): 0 loss,
  0 overruns, 0 capture-fault back-offs in both runs. Live text median 1.28 / 1.31 s, **p95 4.34 / 3.29 s**
  (T19: 2.16 / 5.25 s). One of the two runs is above 4 s under this extra load, which is heavier than the
  real-recording replays. Peak footprint: app 118–119 MiB, worker 858–906 MiB (T19: 126 / 873). Evidence
  `t20-live-load.jsonl`, `t20-live-load-after-review.jsonl`.

Tests:
- `finalFlushKeepsTheLastWords`: Stop lands mid-speech, 1.9 s after the last pass. The flush settles every word,
  the closing words match the reference, nothing is emitted twice, WER 1.9%.
- `latencyBreakdownSumsToTheDelayAndLogHoldsNoText`: the three parts sum to the delay, the flush adds no samples,
  and the saved log holds no text.
- `liveTranscriberSettlesWordsIncrementally` is unchanged and still passes (2.1% / 1.1%).

## Acceptance (T20)

| Criterion | Status |
|---|---|
| Persist live latency samples per meeting (metrics only) | Met: `live-latency.json` per meeting |
| Measure the floor; try a shorter tick and commit interval for live reads only | Measured (breakdown above). Per-source requests and a 0.25 s check adopted. Shorter commit intervals were ruled out by the user (segments stay 2 s) |
| Padded final-window flush at Stop (item 23) | Met: `LiveTextModel.finish` with `LiveRequest.final` |
| G4: median ≤ 2 s and p95 ≤ 4 s on real recordings | **Met** on real-time replays of real recordings: pooled median 1.19 s and p95 3.40 s over 4,946 words (t20b; t20a 1.18 / 3.13 s), and every meeting under 4 s. Live calls with a real meeting app remain Milestone F (T12). Base M2 is unverified |
| Live word error rate within +1 point; final transcripts unchanged | Met: +0.2 points on average; the final pipeline is untouched |

## Limits and follow-ups

- **Replay, not live calls.** The recordings are real, but they are replayed through a synthetic source, not
  captured from a meeting app. Real calls are Milestone F (T12); `live-latency.json` from the user's own meetings
  will show the real figure.
- **Floor.** With 2 s segments, about 1 s of the median is waiting for the segment to be saved. Going lower needs
  shorter segments or reading unsaved audio, which the user ruled out for now.
- **Under heavy load** (live-load), p95 was 4.34 s in one of two runs (3.29 s in the other). If real meetings show the same, a second live decoder in the
  worker would let both sources decode at once (about 5 MiB).
- The 2-minute meeting's mic track (laptop mic, few words) swings most against its final transcript: 11.3% in both
  v1-settings runs, then 4.8% and 1.6% with T20. Its small word count makes it noisy.
- `live-suite` numbers the work-Mac meetings (`corpus-work-mac-N`, in manifest order), because their titles name
  colleagues. Per-run `outputs/` are not committed.

## Review

An independent Sonnet review of the T20 changes (before commit) found:
- the replay spec, with private library paths and meeting IDs, was written beside the committed reports. It now
  goes into the gitignored `outputs/`, and the three runs' specs were moved there;
- a race at Stop if a new recording started while a pass was in flight. Live text now detaches before the flush
  awaits anything, and in-flight bookkeeping is per recording;
- the flush was skipped when live text was paused at Stop. It now runs;
- the doc wording issues fixed above: the segment-wait label, the run count, and agreement with final.

All automated checks (`scripts/check.sh`) pass after the fixes, and `live-latency` and `live-load` were re-run on
the final code.

