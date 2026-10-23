# Milestone E: Local model performance and delay reduction (proposed)

Date: 2026-10-22 · Status: **Accepted (user decisions 2026-10-22, decision record 0004).** Tasks T16–T21 are in
`implementation-tasks.json`. Milestone F (release qualification: T12, T13) follows this milestone.

## Goal

**Transcription has to keep up with back-to-back meetings.** The user can't guarantee minutes of idle time between
calls. Under today's policy, heavy processing is suspended while any recording is active. Back-to-back meetings
therefore queue up, and nothing is processed until the user stops recording altogether.

Priorities, in order:
1. **Stop → final transcript** with speakers: as fast as possible, and never blocked by the next recording.
2. **Live text:** speech → provisional words on screen.
3. **Stop → notes:** runs in the background and may be slower, but must not delay any transcript.

Speed takes priority over small transcription-quality losses (bounded below). Notes quality is kept.
Validation is automated, so the user's ongoing role is limited to supplying recordings once (see "Test corpus").

## Where the time goes today (M2 Max, 60-minute two-source meeting)

From `docs/qualification/evidence/2026-10-16/processing-timing-60min.json` (cold and warm runs agree within 1 s).
**T16 (2026-10-22): these figures came from a Debug build.** On Release, the same meeting gives its transcript in 105 s
and notes in about 260 s; see `docs/qualification/milestone-e-t16-breakdown.md`.

| Stage | Seconds after Stop | Same work in isolation (models/0001, asr/0001) | Gap |
|---|---|---|---|
| Prepare (resample both sources) | 35 | – (resampling 2 h of audio should take a few seconds) | ? |
| Transcribe (both sources) | 177 | Parakeet RTF ≈ 0.0035 → **~25 s** for 2 × 60 min | **~7×** |
| Diarize (system source only) | 255 | **~21 s** for 60 min | **~12×** |
| Reconcile | 2 | – | – |
| Notes | 297 | 200–204 s in `notes-eval` | 1.5× |
| **Total** | **589 (≈ 10 min)** | | |

- Every stage runs strictly one after another, and all heavy stages wait for Stop
  (processing/0001: "suspended while a recording is active").
- The user's first real meeting (2 min) had its final transcript about 18 s after Stop and notes about 45 s after
  Stop. Fixed per-job overhead dominates short meetings.
- Live text: median 2.18 s, p95 4.99 s, measured on synthetic replay only (live/0001).

**The main finding is the gap column.** The models are fast; the pipeline around them is not. Nobody has explained
the 7–12× overhead yet, so the first task measures before anything is optimised.

## Targets (M2 Max measured, base M2 projected and marked unverified)

| # | Gate | Today | After batch work (T17–T18) | After incremental work (T19) |
|---|---|---|---|---|
| G1 | Stop → final transcript with speakers, 60-min meeting | ~470 s | ≤ 60 s | ≤ 20 s |
| G2 | Stop → notes, 60-min meeting (background, lower priority than any transcription) | ~590 s | ≤ 5 min | ≤ 5 min |
| G3 | Batch path, 60 min (recovered or imported meeting with no incremental results): transcript | ~470 s | ≤ 60 s | ≤ 60 s |
| G4 | Live text delay, real recordings | 2.2 s / 5.0 s (synthetic) | – | median ≤ 2 s, p95 ≤ 4 s |
| G5 | Quality guard (below) | baseline | must hold | must hold |
| G6 | Capture safety while processing runs during a call | n/a (paused today) | – | zero missing audio, zero ring overruns, capture footprint budget unchanged |
| G7 | Back-to-back: two consecutive 60-min meetings with no gap | meeting 1 waits for meeting 2 to end | – | meeting 1's final transcript ready while meeting 2 records; queue does not grow |

**G5 quality guard**, checked automatically on every change against a frozen v0 baseline. Transcription may trade a
little quality for speed (user decision 2026-10-22); notes may not. The bounds are adjustable if they block a large
speed win, but only with the user's agreement:
- **Transcription, public suite:** WER no worse than +1.0 point per set; DER no worse than +2.0 points; attribution
  "labelled" and "correct" no worse than −1.0 point; `failed` coverage seconds no more than 25% higher; silence, noise
  and music controls still give 0 words; boundary fixtures pass (first and last words, numbers, dates, negations).
- **Notes:** 100% valid evidence; planted coverage 6/6; injection suite 10/10; uncertain-item share no higher than
  baseline + 5 points.
- **User corpus (no labels needed):** word-level agreement with the baseline transcript, speaker agreement after
  optimal mapping, and notes item overlap. Any meeting below threshold is listed in the report for review.
- **Pure refactors** (scheduling, I/O, batching) must produce **byte-identical** transcripts to the baseline. Any
  change in output means the change was not a pure refactor.

## Tasks

### T16: Measurement and automated validation harness (first; everything else depends on it)
- Add `os_signpost` intervals and a per-job timing breakdown inside the worker:
  - **ASR:** VAD, window reads, decode, under-yield retries, checkpoint writes.
  - **Diarization:** segmentation, embeddings, clustering, echo analysis.
  - **Notes:** model load, prefill and generation per call, verification count.
  - **Scheduler:** idle time between jobs.
- `amaranth-bench perf-suite` runs the public suite plus the user corpus through the **real XPC worker and app
  scheduler** (not a harness shortcut). It measures cold and warm runs and writes:
  - `Benchmarks/Results/<date>-perf/measurements.json` (machine-readable);
  - `report.md`: per-stage times, G1–G6 status, quality deltas, and meetings flagged for review.
- Freeze the **v0 baseline**: outputs and metrics of the current pipeline for every corpus file, stored with the
  corpus (gitignored). Pipeline, model and OS hashes are recorded.
- `--compare <baseline>` fails non-zero on any G5 breach, so each task can be validated unattended.
- **Exit:** a written breakdown that explains the 7× and 12× gaps, with evidence.

### T17: Remove pipeline overhead (no model changes)
**Result (2026-10-22):** G1 and G3 met in batch, at 53–54 s for 60 minutes (v0: 105 s), with byte-identical output.
Transcription and diarization now overlap, and ASR windows are decoded by 2 concurrent instances. See
`docs/decisions/processing/0002-concurrent-analysis.md`.

Candidate levers. **T16's breakdown decides which ones are real; none is assumed.**
- **Prepare:** stream the resampling, or produce the 16 kHz derivative incrementally while recording (it is pure DSP).
- **Overlap stages:**
  - transcribe and diarize are independent in the DAG but run serially;
  - Parakeet runs mostly on the Neural Engine, and the diarizer's segmentation and embeddings can be pinned to the
    GPU or CPU to avoid contention.
  - This needs a measured memory and thermal check, because plan §10 asks for "one heavy stage at a time".
- **Transcribe overhead:** windows with 2 s of context on each side; retry rate of the under-yield guard; per-window
  file I/O and checkpoint fsyncs; batching Core ML predictions.
- **Diarize overhead:** find why the production call is about 12× slower than the T02 measurement. Check the file
  vs sample-buffer path, the compute-unit choices (FBank is pinned to CPU) and the per-block manager re-initialisation.
- **Warm start:** Core ML warm-up at install (tracked item 3); keep the worker and models warm between jobs;
  cut scheduler idle gaps.
- **Exit:** G1 ≤ 60 s and G3 met. Pure refactors are byte-identical to the baseline; deliberate speed/quality trades
  stay within G5.

### T18: Faster notes
**Result (2026-10-22):** G2 met at 144–149 s for 60 minutes (v0: 248–252 s); 120-minute notes 266 s (v0: 536 s).
G5 notes checks pass (evidence 100%, planted 8/8, injection 10/10, uncertain 33.0% vs 38.6%). Notes are generated
16 sequences at a time with compact JSON output, and they yield to transcription work and resume from checkpoints
(a meeting arriving during notes: transcript 8.5 s vs 7.8 s alone). Draft-model speculation, quantised KV and
Qwen3-1.7B (fails planted 3/8 and injection 8/10) were measured and not used. See
`docs/decisions/notes/0002-faster-notes.md`.

- Profile first (T16). The 60-minute notes job is about 3 extraction chunks plus up to 120 verification calls.
- **Levers, cheapest first:**
  - batch verification (several items per call against shared cited lines);
  - cap extracted items earlier (96 extracted, then capped, in notes/0001);
  - terser grammar output;
  - reuse the KV cache across chunks;
  - llama.cpp flash attention and quantised KV;
  - speculative decoding with a small draft model (for example Qwen3-0.6B);
  - and only then a smaller main model (Qwen3-1.7B, already measured at 2.5× faster, quality untested).
- Any model change bumps the model pack and must also pass the absolute notes checks, not just the baseline
  comparison.
- **Scheduling:** notes run at the lowest priority. Any transcription work, for this or a newer meeting, preempts
  them at the next checkpoint.
- **Exit:** G2 ≤ 5 min, with G5 notes checks passing and no transcript delayed by notes.

### T19: Incremental processing during the meeting (the largest win)
**Result (2026-10-23):** Transcription runs during the recording, and at Stop the normal stage reuses identical windows,
so transcripts stay byte-identical to v0. A 60-minute meeting's transcript with speakers is ready 21.0 s after Stop
(batch 50 s); speaker finding at Stop (about 19 s) is now the whole critical path. **G1 ≤ 20 s not met** (speakers stay
at Stop and notes are not drafted during the meeting, by user decision; the 120-minute case was not measured). G7 met
(back-to-back: meeting 1 ready 22 s after its Stop while meeting 2 records). G6 met for synthetic sources (0 loss,
live latency unchanged). See `docs/decisions/processing/0003-processing-while-recording.md`.

Today all heavy work waits for Stop. The machine is mostly idle during a call: live text uses about 70 ms of
compute per 10 s of audio.
- **Prepare and final ASR during recording.** The final pipeline's windows only need VAD cut points, so final-quality
  windows can be decoded about 30 s behind live, with the same 2 s context and under-yield guard. At Stop only the
  tail remains.
  - The same results can replace provisional live text as they arrive, so live text also gets more accurate.
  - live/0001 deferred reusing *live* chunks because live passes use energy rather than VAD and lack right context.
    This approach does not reuse live output: it runs the **final** pipeline early.
- **Diarization:** run segmentation and embeddings incrementally, then do global clustering once at Stop
  (clustering is the cheap part). This depends on what FluidAudio's offline API exposes. The fallback is per-block
  diarization during the meeting plus the existing cross-block linking, which needs tracked item 11 (over-splitting)
  fixed first.
- **Notes:** run the map phase over finalized ~5,000-token chunks during the meeting, keyed to time spans rather than
  speaker labels. At Stop, re-attach owners from the final speakers, run the remaining verification, then reduce
  and write the overview.
- **Guarded by G6** (user decision 2026-10-22: try it, roll back if problems slip past the safeguards).
  - Incremental work runs at low priority.
  - It backs off at serious thermal state or under memory pressure.
  - It pauses on any capture fault, and never touches the realtime path.
  - A self-test runs it against a simulated call load.
  - **Rollback:** one setting, "Process while recording" (on by default), restores the v0 policy of suspending heavy
    work while recording.
- **Back-to-back (G7):** when meeting 2 starts, meeting 1's remaining tail work keeps running under the same
  guards, instead of being suspended until meeting 2 ends.
- **Exit:** G1 ≤ 20 s for 60- and 120-minute meetings; G5, G6 and G7 hold.

### T20: Live text latency (small)
- Measure the floor: 2 s segment commits, a 2 s tick, and the stable-word rule (1.5 s after a pause).
- Try a 1 s tick and shorter commit intervals for live reads only. Durable segments stay the only input
  (live/0001 rule).
- **Exit:** G4 met on real recordings.

### T21: Milestone qualification
- Run the full perf suite on release builds with all hashes recorded. Update the decision records (asr, diarization,
  notes, processing, live).
- **Sonnet validator verdict**, required before commit (project rule).
- Base M2 results remain projections, marked unverified.

**Order:** T16 → (T17 ∥ T18) → T19 → T20 → T21. T17 and T18 touch different modules and can run in parallel.

## Test corpus: what to provide

Recordings live in `Tests/Data/Recordings/` (gitignored). **Nothing from it is ever committed:**
reports contain metrics and meeting IDs only, never transcript text (plan §10).

| Tier | You provide | What it enables |
|---|---|---|
| **1 (enough for this milestone)** | Audio or video files (anything AVFoundation reads: .m4a, .mp4, .mov, .wav, .mp3) plus a `manifest.csv` | All speed measurements; regression against the v0 baseline (detects *changes*, not absolute accuracy) |
| 2 | A transcript with speaker names and timestamps (.vtt, .srt or .txt), marked `verified` or `auto` | Absolute WER; with timestamps, DER and attribution |
| 3 | A short list of the decisions and action items per meeting | Notes recall against the plan §10 gates |

Recommendations:
- **Best source: meetings recorded in Amaranth itself.** They already have separate mic and system tracks, which is
  the path the product actually uses. List their titles in the manifest, and the harness replays their stored
  segments directly, with no export.
- Single-track (mixed) recordings work for speed and are fed as system audio. They don't exercise the mic and echo
  path. If Zoom's "separate audio file per participant" option is available, those files are better.
- **Size for this milestone:** 6–10 recordings from 5 min to 2 h, including at least two of 60 min or more, a range
  of speaker counts and at least one noisy one. The plan §10 quality corpus (12 recordings, 4 h, human-labelled) is
  still needed for Milestone D's gates. This set can grow into it.
- **Cheap tier-2 references:** meeting-app auto transcripts (Zoom, Teams and Meet exports) are useful as weak
  references, mainly for speaker turns. The harness can also draft a reference overnight with a slower second model
  (Whisper large-v3) and list only the spans where it disagrees with Amaranth, so verification means checking those
  spans rather than whole meetings.
- **Consent:** record `consent=yes` for every file; the harness skips files without it.

`manifest.csv` columns:
- `file_or_amaranth_title`, `consent` (yes), `speakers` (a number, `N+` or a range);
- `setting`: remote (own devices, mixed call audio), headset, laptop, room, speakerphone or unknown;
- `language`;
- `reference` (none, auto or verified), `reference_file` (transcript), `notes_reference_file` (decisions and actions);
- `split` (dev, heldout, or blank for automatic);
- `duration_s`, `recorded`, `tracks` (mixed-stereo, or separate mic and system), `notes`.
- `library` (optional, Amaranth meetings only): a library copied from another Mac, relative to
  `Tests/Data/Recordings/` (for example `libraries/work-mac`; copy `amaranth.sqlite*` and `meetings/` with the app
  quit). Blank means this Mac's library. The meeting is found by title, or by meeting ID when titles repeat.

The held-out set stays fixed and is never used for tuning. The first corpus (2026-10-22) has 4 recordings, 2.8 h, all
mixed single-track Google Meet calls. Two have Gemini auto-transcripts; one is held out (`hangout-ruby-session`).

## User decisions (2026-10-22; decision record 0004)
1. **Processing during recording: allowed.** Plan §10 and processing/0001 paused heavy inference while recording.
   T19 replaces that with "allowed while G6 holds, with automatic back-off", plus a one-setting rollback. The user
   will report problems the safeguards miss.
2. **Speed first for transcription.** Small, bounded transcription-quality losses are acceptable (G5). Notes run in
   the background, may be slower, and keep their quality checks.
3. **Milestone order.** Milestone D is reduced to T14 (live text). T12 and T13 move to a new final Milestone F,
   release qualification, which runs after this milestone and measures its pipeline.
