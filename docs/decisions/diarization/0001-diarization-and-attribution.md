# Diarization 0001: Speaker separation, attribution and correction (T07)

Date: 2026-10-16 · Task: T07 · Status: Accepted for v0. **The plan §10 DER gate is not met on AMI.** The attribution
gates are met on AMI. The real-call corpus is pending.

## Decision

**Diarizer** (`Diarization/FluidDiarizer.swift`). FluidAudio's offline pipeline (pyannote segmentation, WeSpeaker
embeddings, PLDA, VBx clustering) is built by hand from local `.mlmodelc` files. There is no Hub access
(models/0002).
- `exclusiveSegments = false`: overlapped speech is kept as overlap, not forced to one speaker. This lowered DER on
  every AMI meeting.
- **Meetings longer than 1 h are processed in 30-minute blocks.** Each block gets a fresh manager in a detached task,
  so features never accumulate. Block clusters are linked meeting-wide by centroid cosine similarity with a
  Hungarian assignment (`LinkAssignment`). Speaker IDs are session-scoped.

**Attribution** (`Domain/Attribution/MeetingReconciler.swift`). Each word gets the speaker whose turns cover most of
its interval:
- `.multiple` in overlap;
- `.unknown` when nothing covers it;
- uncertain candidates are kept on the word.

Source identity is never treated as one human:
- **personal-mic mode** proposes one local speaker for the mic, which the user can correct;
- **room mode** diarizes the mic as well.

**Echo/duplicates.** A system-output word that reappears in the mic is matched at the measured delay. Matches are
*flagged* reversibly, never deleted, so genuine interruptions survive.
- `EchoAnalyzer` estimates one global delay. It cross-correlates log energy envelopes over the first 10 minutes, at
  lags of 0–500 ms in 10 ms steps, and accepts a correlation above 0.5.
- Words are then matched within 1 s, in groups of 3 or more.
- `findsTheEchoDelayAndRejectsUnrelatedAudio`, on synthetic speech-like bursts: 60, 180 and 350 ms delays are
  recovered within ±15 ms while a quieter local talker is present. Unrelated audio gives no delay (not a spurious
  one), and audio under 5 s gives none.
- **Limits:** a single global delay (a delay that drifts or changes route mid-meeting is not tracked), echo paths
  over 500 ms, and real-room acoustics are untested. A missed match fails safe: the duplicate words are kept, just not flagged.

**Cancellation and liveness.** A diarization engine call runs through `EngineCall`:
- A `CancellationToken` cancel stops the call at FluidAudio's next internal checkpoint. Measured on a 36-minute
  meeting: stopped 0.41–0.45 s after cancel. The cached diarizer gives a normal result on the next job
  (`cancellingMidMeetingStopsWithinSeconds`).
- Liveness ticks reach the worker's hang watchdog every 5 s while the call is within its budget of 10% of real time
  (at least 120 s; the M2 Max runs at about 0.6%). After that the ticks stop, so a truly hung call is still detected
  (`ticksStopAtTheBudgetSoAHungCallIsStillDetected`).
- This means a recording that starts mid-diarize interrupts it promptly, and slower hardware does not trigger a
  false recycle.

**Corrections.** `EditOperation`s are rename, merge and reassign (word range). They are stored as edits over a base
revision. On reprocessing, each edit is rebased onto the new revision; an ambiguous rebase is surfaced as
`needsReview` rather than silently overwritten. Names are never inferred.

## Measurements

Production evaluation, current code
([`production-eval-asr-v8.txt`](../../qualification/evidence/2026-10-16/production-eval-asr-v8.txt)). DER uses no
collar and scores overlap.

**Metric definitions** (`productionEval` in `Benchmarks/Harness/main.swift`). Both are word-based proxies for the plan
§10 attribution metrics:
- **Labelled:** among *ASR-emitted* words whose midpoint falls where exactly one reference speaker talks, the share
  that received exactly one speaker. Because the base is ASR words, not reference speech time, ASR deletions are not
  penalised here; they show up in WER.
- **Correct:** among those labelled words, the share whose speaker maps to the reference speaker under DER's optimal
  one-to-one mapping. Speakers with no mapping count as wrong.

These are measured on AMI headset mixes, not on the held-out real-call set.

| Meeting | DER | Missed / FA / confusion (s) | Speakers (ref 4) | Labelled | Correct |
|---|---|---|---|---|---|
| ES2004a headset (clean) | 22.2% | 150 / 27 / 29 | 4 | 97.6% | 98.3% |
| IS1009a headset (clean) | 23.1% | 89 / 32 / 40 | 4 | 97.5% | 97.5% |
| EN2002a headset (clean) | 27.6% | 454 / 57 / 187 | 4 | 96.3% | 95.9% |
| ES2004a far-field (difficult) | 27.6% | 188 / 33 / 34 | 4 | 97.1% | 97.9% |
| **Clean aggregate** | – | – | – | **96.9%** (gate ≥ 80%) | **96.8%** (gate ≥ 90%) |

- **DER gate (≤ 20% clean, ≤ 30% difficult): clean not met (22–28%); difficult met (27.6%).** The error is mostly
  *missed* speech in overlapping talk (EN2002a has 153 overlap regions). Confusion is small, which agrees with the
  high attribution precision.
- **Memory** ([`diar-memory.txt`](../../../Benchmarks/Results/2026-10-16-t02-run1/diar-memory.txt), streaming
  harness). Peak footprint with 30-minute blocks: 1.10 GiB at 2 h, 1.08 GiB at 4 h (flat). Full-file processing
  grows from 1.18 to 1.27 GiB.
- **Cross-block identity.** AMI forced into 5-minute blocks (≥ 3 links) keeps 4 speakers. DER cost is +3.6 points
  on ES2004a and +0.4 on IS1009a (`blockwiseLinkingKeepsMeetingWideIdentities`). On the synthetic 2 h and 4 h
  concatenations, blocks find 11 clusters where full-file finds 8. Linking over-splits some identities across blocks
  (tracked).

## Acceptance (T07)

| Criterion | Evidence | Status |
|---|---|---|
| Clean/difficult DER, assigned coverage and attribution precision meet §10 | Table above | **Attribution met. DER not met on clean AMI.** Held-out real calls are pending. |
| Eight-speaker / short-turn / overlap fixtures keep uncertainty and invent no names | `eightSpeakerShortTurnsKeepUncertaintyAndNoNames`, `attributesByIntersectionAndAbstainsHonestly` | Met (synthetic turns) |
| Concurrent local speech during remote playback is kept; duplicate suppression never erases real interruptions | `echoIsFlaggedReversiblyAndRealInterruptionsSurvive` (idealised synthetic word timing); delay measurement in `findsTheEchoDelayAndRejectsUnrelatedAudio` | Met on synthetic data; real-room echo is part of the manual matrix (tracked item 1) |
| Reprocessing keeps user corrections or exposes a rebase conflict | `editsSurviveReprocessingOrAskForReview`; scheduler `editsDuringReconcileAreNotOverwritten`, `resultComputedFromStaleEditsIsDiscardedAndRecomputed` | Met |
| 2–4 h clustering memory is bounded | diar-memory.txt | Met (flat at about 1.1 GiB). Measured on a synthetic concatenation, a single run, in a streaming harness rather than through the worker. |
| Personal-mic and room modes | `personalMicProposesOneLocalSpeakerAndRoomModeDiarizesMic` | Met |

## Fallback status

The task fallback is "Evaluate SpeakerKit or improve window/clustering integration." SpeakerKit (argmax-oss-swift
1.1.1) is pinned but not yet evaluated head-to-head on the overlap-heavy meetings. That comparison is the next step
on the DER gap (tracked item 4).
