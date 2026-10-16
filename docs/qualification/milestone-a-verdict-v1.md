# Milestone A independent validation verdict

Validator run: 2026-10-16, M2 Max / macOS 26.5.2. No repo source modified. I did not run any audio-capture self-test, soak or browser script.

## Overall: PASS WITH CONDITIONS

What I ran:
- `scripts/check.sh` passed: 67 tests in 10 suites, app and XPC worker build, and the `os-gate`, `worker-crash` and `worker-hang` self-tests against the real bundle.
- A release build of `amaranth-bench` and `amaranth-models` under `/tmp/amaranth-validate`.
- The `amaranth-bench ... --score-only` re-score.
- `amaranth-models verify --full`, a rebuild of the pack manifest, and an independent sha256/size check of the installed pack.
- A read of `Capture/RealtimeC/amr_realtime.c`, `Models/ModelInstaller.swift` and the evidence JSONL.

The milestone is substantively met. The unverified gates (base M2/16 GB, 8 GB, real-call held-out set, manual meeting-app matrix) are honestly labelled as unverified or pending throughout the docs. The conditions are:
- one real functional bug in the T04 repair path;
- several places where a doc cites a cherry-picked or slightly inaccurate figure;
- gaps relevant to the promoted live-text requirement.

## T01: Contracts and project. MET

Evidence checked:
- `check.sh` builds the app plus embedded XPC worker with Xcode 26.6 and Swift 6.3.3. `Package.swift` and `Package.resolved` use exact pins: FluidAudio 0.17.7, argmax 1.1.1, llama.cpp b11669 with a checksum. I found no branch pins.
- The contract tests cover round trips for source, overlapping intervals, unknown speakers, null owners and evidence kinds. They also cover rejection of newer contract versions and inverted intervals, and provisional vs final revisions.
- `worker-crash` and `worker-hang` passed against the real `.app`. The worker calls `abort()` and the app stays alive.
- `capturedAudioDistinctFromFailedProcessing` asserts audio `savedWithGaps` alongside a failed notes stage. There is a `FixtureLibraryView` for the fixture UI. I did not visually inspect the UI.
- `0001`, `0002` and `0003` document the confirmed choices. `0003` records live text as promoted and the unavailable hardware as unverified.

Unmet or unverifiable:
- I did not exercise the fixture UI itself. The distinction is verified at the state-model level only.
- The worker is only the fake or crash-injection worker. No real inference runs through XPC yet. That is fine for M-A, but T08 inherits that risk.

## T02: Model harness and selection. MET WITH CAVEATS

Evidence checked:
- I re-scored the cached raw results. Every headline number in `models/0001-model-selection.md` reproduced exactly:
  - AMI clean WER: v2 27.9%, v3 27.3%, int8v2 26.5%, Whisper 35.3%.
  - Non-overlap WER: 11.5%, 13.8%, 13.1%, 23.2%.
  - Far-field non-overlap WER: 23.2%, 20.4%, 20.4%, 53.1%.
  - Read speech WER: 1.5%, 1.4%, 2.5%, 2.6%.
  - Timing medians 63/80/80/70 ms.
  - Diarization DER 23.9%, 24.1%, 34.9% and 29.0%, with speakers 4/4 each.
  - Controls produced 0 words and `noSpeechDetected`.
- 60- and 120-minute ASR, diarization and notes runs exist in `report.json` and `raw/`. For example, v3 ASR takes 13.5 s for 60 min and 23.9 s for 120 min. Whisper takes 363 s and 708 s. Diarization RTF is about 0.006.
- Cancellation evidence is in `evidence/cancel-test.txt`: 0.06 s, 0.24 s and 0.00 s. The doc quotes 0.03/0.21/0.01, which are the same order but not the same numbers as the committed file.
- The pins are in `candidates.md`. The harness runs offline, and the model revisions and file hashes are in the manifests.
- The decision doc declares the 16 GB gate "GO, projected", and 8 GB "UNVERIFIED". Base-M2 projections are labelled as projections.

Overstated, unsupported or unvalidated:
1. **The "real 60/120-minute" runs are concatenations of the same three AMI meetings (about 67 min of unique audio, so the 120-minute input repeats material).** The README says "throughput and memory only", which is honest. But speakers come out as 8, and notes on those inputs say nothing about quality. The doc's phrase "60 min of meeting → notes in 80 s" should say "synthetic concatenation".
2. **The "full pipeline" figures are summed per-stage times, not a measured end-to-end run.** The base-M2 figures use guessed multipliers (x1.5 for ANE stages, x4 for the LLM). The decision is correctly "projected". The 60-minute case is about 7 of 10 minutes, with a tight margin. Treat 16 GB GO as a plausibility result only.
3. **The WER gates are met only on the subset the doc picked.**
   - The plan gate is 15% clean and 25% noisy. All-speech clean WER is 27.3%.
   - The doc says it "meets both on non-overlapped speech". Non-overlap is 1,312 words (clean) and only 388 words (far-field), from 3 meetings and 1 far-field recording.
   - All-speech far-field WER is 24.5%, which passes. Non-overlap clean WER is 13.8% on three meetings, which is a thin sample.
   - The overlap deletions are real. The mic and system tracks in the app remove only local/remote overlap.
4. **No tuning vs held-out split exists.** The prompt (v3) was tuned and checked on ES2004a and the injection check is a single case. This is documented as provisional. The "real-call held-out set" is still pending.
5. **Final-window behaviour is validated only at whole-utterance level** (v2 dropping the last 2.3 s on a Libri utterance). Windowed or streaming behaviour is untested. Live text (T14) is now essential, but no streaming ASR latency or stability was measured. This is the largest gap against 0003.
6. **Meeting-wide speaker consistency** was checked only by one full-file offline pass on four recordings. It was not tested at the 2 to 4 h scale or in the live path.
7. The whisper-626MB run: `run.log` shows `whisper-turbo-626mb ami-ES2004a-Mix-Headset` started and no result exists, yet the doc says it "was not run". It was started and ended without a result, so say that.
8. Notes quality is unjudged (the doc admits this). Notes at 120 min depend on a 12-item-per-chunk cap that chunks often hit.
9. The Core ML runtime logs `E5RT ... zero shape error` on every parakeet-v2 item in `run.log`. This is not explained in the doc. It did not change scores, but a pass/fail run with a log full of runtime exceptions needs a one-line explanation.
10. The `mobius` converter for parakeet v3 is unpinned (`main`) in provenance. This is disclosed as a gap, and the weights themselves are pinned and hash-verified.

## T03: Capture spike. MET FOR AUTOMATED GATES, MANUAL MATRIX PENDING (HONESTLY MARKED)

Evidence checked (raw JSONL in `evidence/2026-10-16/`):
- Mic and system are both present and distinct: system tone -10.5 dBFS (the generator is -10.46), mic -35 to -45 dBFS acoustically. This held in runs 2 to 7.
- Self playback is excluded (-240 dB in the system track) in run 7 and the other runs.
- Default input and output UIDs are unchanged (`unchanged:true`). The tap is `.unmuted` in code.
- A process started after recording began was captured. Firefox 136 was captured (16 of 20 windows with tone).
- `capture-routes.jsonl` shows an output switch with no gap, and an input switch with explicit epochs and 61 to 69 ms gaps.
- First frame times of 0.052 s and first commit times of 2.047 s in run 7.
- 30-minute soak: 907 segments per source, 0 overruns, 0 events, `pass:true`, p99 25 us (histogram resolution), max callback 34 us. The soak ran under 6 busy `yes` processes (`meta.json`).
- I read `Capture/RealtimeC/amr_realtime.c`. The IOProc path (`amr_ioproc`, used by both mic and system tap) has no malloc, no locks and no Swift. It uses a preallocated and pre-touched SPSC ring with atomics. Overruns drop whole chunks and are attached to the next chunk via `dropped_frames_before`.
- The matrix honestly marks Chrome as untested (Chrome 119 crashes at launch, `browser-chrome-crashed.jsonl` shows `fail`) and Zoom, Teams, Meet and Slack as pending. The checklist has empty result columns.

Overstated or unmet:
1. **The design doc and matrix cite first-frame times of "45-80 ms over 4 runs" and first commit 2.05 to 2.08 s, and omit `capture-signals-run1-first-permission.jsonl`.**
   - There the system source had first frame 2.035 s and first commit 4.031 s, `gate: fail`, and a `result: fail`.
   - It happened while the TCC prompt was pending. The acceptance criterion says "after permission", so the gate is arguably not applicable.
   - But the design doc says the TCC prompt blocks the start for up to 66 s. A real first run would exceed both limits from app launch. State this explicitly instead of leaving the failing run out of the table.
2. **Zoom/Teams/Meet/Slack trials are not done.** The T03 criterion is not met for those trials. It is marked pending, which is honest. The status string "implemented (manual app/device matrix pending)" is accurate.
3. The soak is a Debug build, ad-hoc signed, with a synthetic CPU load. It is not a meeting-app-loaded run. The soak measures callback duration (the callback's own work), not scheduling latency or deadline misses. "No blocking" rests on code inspection plus 0 overruns, which is reasonable.
4. The "mic follows the default device" behaviour and the 61 to 69 ms gaps were checked only with virtual devices (ManyCam, Teams Audio). No headphones, Bluetooth or USB trials were run. Permission denial and revocation are untested ("denied" is manual).
5. The mic path was never tested with real speech into a real call. It heard tones acoustically only.
6. The permission-prompt blocking behaviour, and that `TCC` re-prompts after ad-hoc rebuilds, are documented as follow-ups for T10.

## T04: Model packaging. MET FOR THE MECHANISM, ONE FUNCTIONAL DEFECT

Evidence checked:
- `amaranth-models verify --full` returns `ready`. An independent sha256 check of 61 installed files (all files under 50 MB plus the GGUF) matched the manifest, and all 62 sizes match.
- `amaranth-models build-pack` regenerated from `ModelStore` (with `--exclude EncoderInt4,Encoder_v2`) produces JSON identical to the committed pack. The bundled `App/Resources/default-model-pack.json` equals `Models/Packs/*.json`. The pack is 62 files, 3.00 GB, with every file carrying a sha256 and a pinned `resolve/<sha>/` URL.
- `verify-pack-offline.txt` shows the run under `sandbox-exec` with network denied, and a curl DNS failure as the check. Results: sample WER 0.0% (one 40-word utterance), diarizer loaded, notes produced 3 items with 0 bad refs, injected claim not adopted.
- In `ModelInstaller.swift` the staging, `.partial`, size and sha256 checks, the delete-on-mismatch, the rename-based activation and the lease logic match the doc. The 9 `ModelsTests` pass and include interrupted, corrupt, space, leased-upgrade, cancel and the no-network-in-registry grep test.
- The corrupt-model path reports `corrupt(...)`, shows record-only, and does not download.
- The conversion provenance is recorded per model, and the diarizer's "not build-attested" status is disclosed.

Defects and gaps:
1. **Repair path is broken (functional bug).** `ModelInstaller.install` on an existing same-version pack hits `if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: staging) }` and keeps the existing copy without verifying it. `ModelPackStore.remove` refuses to remove the active pack. So the UI's "reinstall or import the pack to restore transcription" for a corrupt model cannot actually repair it. A corrupted pack stays corrupt until the user hand-deletes files or bumps the version. No test covers this; the corruption test only checks that it is reported.
2. **HTTP resume restarts poorly.** If a server ignores `Range` (a 200 instead of 206), `HTTPModelSource` throws and leaves the partial in place, so every retry fails the same way. The criterion says "resume or restart cleanly". Only a `resume` with a fake source is tested. Only the 1 MB Silero pack was installed over real HTTPS. The 2.5 GB GGUF has not been downloaded over the network in an install.
3. **Missing license/notice files for two shipped models.** Parakeet v3 and Silero ship a `README.md` but no `LICENSE` or `noticePath`. Parakeet's README says "Apache 2.0", which contradicts the manifest's CC-BY-4.0. Diarizer and Qwen include a LICENSE. The attribution string exists, but the criterion asks for notices per actual shipped asset. Silero's MIT text and NVIDIA's CC-BY notice should be included.
4. **The documented fallback for risk 2 (garbled output) is not shippable.** Only the default encoder is in the pack (483 MB). `Encoder_v2` (int8v2) and the 1.7B 8 GB candidate are not in the pack, so the planned "bounded retry with int8v2" for a garbled window has no model on disk.
5. A staged `final` file is skipped on resume without re-hashing, and activation does not re-verify. The risk is small, because files are only renamed in after hashing.
6. The "compile/warm up" step is a hook that the app never supplies (`ModelInstaller(store:)` in `ModelSetupModel` has no `warmUp`). Core ML compile is done by the bench harness only, so first-load compile cost (16 s for v3) will fall on the first job.
7. The app does not link any inference engine yet. "Disable runtime automatic downloads" is verified in the bench engines (offlineMode, hand-built diarizer, `download: false` plus tokenizerFolder, a local GGUF) and by a source grep test on the registry. It will need re-verification once the engines are in the worker (T06 to T09).

## Required fixes before Milestone B (prioritized)

1. **Fix the T04 repair path.** Make a reinstall or import over an existing same-version pack verify the existing copy and replace it if corrupt (or allow removing a corrupt active pack), and add a test. The UI promises this recovery.
2. **Handle a server that ignores `Range`** (restart that file from zero) and exercise a real HTTPS install of the full pack at least once, including interrupt and resume.
3. **Correct the docs where overstated:**
   - include the failing run 1 and the permission-prompt delay in the T03 gate table;
   - label the 60/120-minute inputs as concatenated AMI;
   - the 626MB run status;
   - the cancellation figures should match `cancel-test.txt`;
   - state that the 15%/25% WER gates are met only on the non-overlap subset (and not on all speech);
   - state that the full-pipeline totals are sums of separately measured stages.
4. **Add the missing license/notice files** for Parakeet v3 (NVIDIA CC-BY-4.0) and Silero (MIT) with `noticePath`, and resolve the README "Apache 2.0" conflict.
5. **Measure streaming/live ASR early** (window boundaries, final-word loss, latency, first-text time) on the M2 Max. Live text is essential (0003), and the batch results do not cover it. Decide on the garbled-output fallback model and add it to the pack, or decide to drop it.
6. **Explain the `E5RT zero shape error` log noise,** or show it is harmless.
7. Run the manual meeting-app and device matrix and the permission denial trials (Zoom, Teams, Meet, Slack, headphones, Bluetooth, USB), before T10/T12 rely on capture. Start capture off the main thread in T10, since tap creation blocks while a prompt is open.

## Acceptable deferrals

- Base-M2/16 GB and 8 GB qualification (the gates remain "unverified"; the docs say so).
- The real-call held-out set, note quality judging, and the broader injection test suite (T09, user data).
- DER below the plan's gate and overlap handling (T07, with SpeakerKit as the bounded fallback).
- Chrome capture testing, once a working Chrome exists.
- Stable team signing and notarization (the user supplies the Apple ID; ad-hoc signing causes re-prompts).
- A Release-mode, 2 h/4 h capture soak (T05/T12), and sleep and crash recovery (T05).
- Compile/warm-up wiring and worker-side offline enforcement (T06 to T08), once real engines run in the XPC worker.
- Unpinned `mobius` converter provenance (disclosed upstream gap).
