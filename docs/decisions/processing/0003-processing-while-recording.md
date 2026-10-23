# Processing 0003: Transcription while recording; back-to-back meetings (T19)

Date: 2026-10-23 · Task: T19 (docs/milestone-e-performance-plan.md) · Status: Accepted (user scope decisions
2026-10-22: speakers stay at Stop, no incremental notes, transcription WER allowance +2.0 points, sped-up replay only,
nothing over 60 minutes). Amends processing/0001 ("suspended while a recording is active") and live/0001 (live text
now also shows final-pipeline words).

## Context

After T17 and T18, a 60-minute two-source meeting had its transcript with speakers 50 s after Stop (G1 batch target
≤ 60 s, met; incremental target ≤ 20 s). All heavy work still waited for Stop, and recording suspended every heavy
stage, so back-to-back meetings queued until the user stopped recording altogether (G7).

The user chose the scope before work started:
- **Speakers stay at Stop.** FluidAudio keeps the fields needed to join per-piece speaker analyses private. The
  alternatives were a local FluidAudio fork, or blockwise speaker finding plus cross-block linking (which first needs
  tracked item 11 fixed). The user chose neither. G1 ≤ 20 s was therefore expected to be missed by about the
  diarization time.
- **No notes during the meeting.** Notes already finish in about 145 s and never delay a transcript.
- **Transcription quality:** up to +2.0 WER points per set allowed. Identical output was the first aim, and it was
  reached.
- **Validation:** sped-up replay only, and no meetings over 60 minutes (the 120-minute half of G1 is not measured).

## Decision

1. **Final-quality transcription while recording** (`ASR/Incremental/IncrementalTranscriber`). It runs the batch
   pipeline's own steps on the audio committed so far:
   - **Derivative.** The 16 kHz derivative is built by `AnalysisPreparer.DerivativeBuilder`, now shared with the
     prepare stage. A segment is placed at its own observed start, and the converter state is continuous per epoch.
     The samples are therefore the ones prepare writes.
   - **VAD.** It runs on the batch chunk grid (600 s, 5 s overlap, from each recorded region's start) and is fed
     block by block (`SileroVAD.Stream`). FluidAudio runs 4,096-sample blocks in order from a fresh state, and the
     model is causal, so the probabilities are exactly the batch ones. Test: `streamedVADMatchesWholeChunkVAD`.
   - **Planning.** Windows come from `TranscriptionPipeline.plan`, now a pure function. Speech is treated as settled
     16 s behind the newest VAD block, to cover the segmenter's 14 s split and its end padding. A decision at a cursor
     looks only at cuts up to `cursor + 14.9 s`, so planning stops at the first decision that could see beyond the
     middle of the silence reaching the settled point. Test: `partialPlansArePrefixesOfTheFullPlan`, which shows every
     partial plan is a prefix of the full plan (5 speech patterns × about 480 horizons each).
   - **Decoding.** Each window is decoded by `TranscriptionPipeline.transcribe`: same contexts, same under-yield guard,
     same checkpoint format. This uses its own Parakeet and VAD instances (about 5 MiB each), so incremental work never
     shares a decoder with live text or with batch jobs.
2. **Reuse at Stop** (`IncrementalReuse`). The prepare and transcribe stages run as before, over the whole meeting.
   The transcribe stage then:
   - compares the incremental derivative with the prepared one byte by byte, and uses only the identical prefix;
   - reuses a VAD chunk if it is the same chunk inside that prefix;
   - reuses a window result if the planned window is identical (span, contexts, VAD speech) and everything a decode or
     re-decode may read (`end + 14.9 s`) lies inside the prefix. Anything else is decoded normally.

   **The final transcript is therefore exactly the batch transcript.** Test:
   `incrementalThenStopGivesTheBatchTranscript`, with a pause mid-recording, 48 kHz stereo and 16 kHz mono sources:
   identical, 46 of 53 windows reused. In the perf suite, all 780 windows of the 60-minute meeting were reused.
3. **Driver** (`App/Processing/IncrementalProcessor`):
   - Every 5 s, one request at a time, it sends the worker the newly committed segments with a 3 s budget
     (`WorkerRequest.incremental`).
   - The worker keeps per-meeting state. A restarted worker gets every segment again, and rebuilt identical windows
     are found on disk.
   - At Stop, a `close` request cancels any work in progress.
   - Live text shows the final words in place of provisional ones (`LiveTranscriptState.applyFinal`).
4. **Scheduler** (`JobScheduler`, `processWhileRecording`):
   - While a meeting records, transcription, speaker finding, prepare and reconcile of earlier meetings keep running.
     Notes still wait for the recording to end (they load a 3.9 GiB model).
   - Back-off outranks recording. Serious or critical thermal state, memory pressure, or a **capture fault** suspend
     heavy work, and incremental processing pauses for the same reasons. A capture fault is a degraded or failed
     source, or a new ring overrun; it holds for 30 s after the last one (`ProcessingModel.observeCapture`, new
     `SuspensionReason.captureFault`).
   - Live text now also pauses under memory pressure. This was the "memory-pressure trigger for live text" deliverable;
     before, it paused for thermal state only.
5. **Rollback:** Settings → Recording → "Process while recording" (on by default; `processWhileRecording` user
   default). Off restores the v0 policy: nothing is processed during a recording, and heavy stages wait for it to end.
   The scheduler setting takes effect at the next launch; incremental processing checks it on every tick.

## Results (Release, M2 Max, perf-suite run `Benchmarks/Results/2026-10-22-perf-t19a/`, `--compare baseline-v0 --require-identical`)

**G5 pass.** There are 0 breaches, and every transcript is byte-identical to v0, including the runs processed while
recording. The 6 corpus flags are notes-wording overlap only, expected since notes-v2 (notes/0002). The 120-minute
item was stopped part-way at the user's request and is excluded from the score.

| Seconds after Stop | Batch (T18 path) | While recording (T19) |
|---|---|---|
| timing-2src-60min: transcript with speakers | 50.1 / 50.4 (cold / warm) | **21.0** |
| of which transcribe / diarize exec | 46.7 / 45.0 | 1.7 / 19.0 |
| corpus-working-session (72 min, one source) | 34.4 | **23.3** (transcribe 0.8, diarize 19.5) |
| timing-2src-60min: notes | 145.3 | 114.4 |

- Replay ran at 10× realtime: a 60-minute meeting takes 363 s, with 72 requests, none busy, failed or paused. When
  recording stopped, final-quality text reached 3,566–3,568 s of 3,624 s.
- **G1 (≤ 20 s): not met, by about 1 s for 60 minutes**, as expected from the scope decision. Speaker finding at
  Stop is now the whole critical path, at about 19–20 s for a 60-minute system track. The 120-minute case was not
  measured (user decision: nothing over 60 minutes).
- **G7: met.** Two 60-minute meetings ran back to back. Meeting 1's transcript was ready 21.7 s after its Stop,
  while meeting 2 was still recording (meeting 2 stopped 363 s later). No meeting-1 transcript stage was left when
  meeting 2 stopped. Meeting 2 was ready 20.9 s after its own Stop.
- **G6: met for synthetic sources** (`Amaranth --self-test live-load`; evidence
  `docs/qualification/evidence/2026-10-23/t19-live-load.jsonl`). This is a two-source recording in real time (125 s),
  with live text, incremental processing, and every stage of an earlier 20-minute meeting running alongside:

  | | live-latency (no load) | live-load |
  |---|---|---|
  | Missing-audio events / ring overruns / capture-fault back-offs | 0 / 0 / – | 0 / 0 / 0 |
  | Live text latency, median / p95 | 2.18 / 5.18 s | 2.16 / 5.25 s |
  | Provisional mic WER | 2.4% | 1.2% (final words replace live ones) |
  | Peak footprint, app / worker | 91 / 45 MiB | 126 / 873 MiB |

  - The earlier meeting finished all its stages during the recording.
  - The app's extra 35 MiB is committing that meeting's stage results, not capture. The capture path is unchanged,
    and the app stays well inside the plan's 350 MiB limit.
  - The live gate (median < 5 s, p95 < 10 s) still holds. G4's tighter target is T20.

## Limits and follow-ups

- **G1 ≤ 20 s** needs speaker finding during the meeting, which needs FluidAudio's prepared segmentation and
  embeddings to be joinable (fork or upstream change) or tracked item 11 fixed. This was out of scope by user
  decision (tracked item 25).
- **Notes during the meeting:** skipped (tracked item 26).
- **Evidence limits:** G6 and G7 used sped-up or short real-time synthetic replay. They have not been run on a real
  call with a real meeting app (manual checklist, Milestone F), and nothing over 60 minutes was measured.
- **Lag at Stop:** final text lags live by about 30–40 s (16 s VAD settling, one window, the 5 s tick). At Stop, the
  tail is decoded by the normal transcribe stage and runs beside speaker finding.
- **Perf suite:** the during-recording runs are opt-in (`perf-suite run --suites …,incremental`). They add a
  during-recording run and a back-to-back pair of the 60-minute meeting.
