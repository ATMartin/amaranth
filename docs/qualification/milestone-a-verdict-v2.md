# Milestone A re-verification (v2)

Same ground rules: no capture self-tests, no repo changes, scratch under /tmp. The earlier verdict is /tmp/milestone-a-verdict.md.

## Overall: PASS. I am satisfied for the project to proceed to Milestone B, with the conditions below carried as tracked items.

None of the conditions blocks starting Milestone B. Two of them (the manual capture matrix and the live-text WER work) must be closed before T10/T12/T14 rely on them.

## Re-verification of the seven fixes

1. **T04 repair path: FIXED.**
   - Code read in `Models/ModelInstaller.swift`:
     - A same-version reinstall fully hashes the existing copy (`Self.verify`, size plus sha256 of every file).
     - If intact, it only reactivates.
     - If damaged and leased, it throws `packInUse`.
     - Otherwise it stages a fresh copy and swaps it in with `renamex_np(RENAME_SWAP)`, then deletes the damaged copy.
   - I ran `swift test` myself (`--scratch-path /tmp/amaranth-validate`): 72 tests in 11 suites passed. The new `reinstallingSameVersionRepairsCorruptPack`, `intactReinstallActivatesWithoutRefetching` and `damagedPackInUseIsNotModified` passed.
   - Remaining nit, not blocking: the damaged copy, once swapped out, is deleted with `try?`, so a failure there leaves a stale staging directory that the next install resumes into. Harmless, because staged files are re-hashed on fetch and only renamed in after hashing.
2. **HTTP Range ignored: FIXED, with a caveat on the real-network evidence.**
   - Code: on HTTP 200 with a nonzero offset, `HTTPModelSource` truncates the partial and restarts the file, and reports negative progress so the counter stays correct.
   - Mock-URLProtocol tests for 206 resume and 200 restart pass.
   - `https-full-pack-install-interrupted-resumed.log` shows a real HTTPS install of pack 0.1.1 killed after 25 s with active=none and 496 MB on disk, then resumed to `done`, with `verify --full` returning `ready`.
   - Caveat: the kill landed on a file boundary at 16.6%, so the real-server `Range` path (206 mid-file) is covered only by the mock tests. Acceptable.
3. **Doc corrections: MOSTLY FIXED, one stale line remains.**
   - Verified in `models/0001`, `capture/0001`, and `capture-matrix.md`:
     - Run 1 failing (2.035 s / 4.031 s, prompt open) and the prompt delay are now in the T03 gate table.
     - Cancellation figures are 0.06 / 0.24 s, matching `cancel-test.txt`.
     - The non-overlap WER caveat is stated, with all-speech clean failing.
     - Pipeline totals are labelled as sums of separately measured stages on concatenated AMI audio.
     - The 626 MB run is described as started and then stopped. I cannot confirm that it was "deliberately" stopped, because `run.log` shows only that it started with no result. Minor wording point.
   - **Still stale:** `models/0001` "Risks carried forward" item 2 (line 165) still says to use "the int8v2 or v2 path as the fallback for a window". That contradicts the new Garbled-output fallback section, which says int8v2 is not a fallback and no second encoder ships. Fix that line.
4. **Notices: FIXED.**
   - Pack 0.1.1 has a `noticePath` on all four manifests, each present in the manifest's file list: Parakeet `LICENSE.CC-BY-4.0.txt` (the text starts with the Creative Commons Attribution 4.0 International legal text), Silero `LICENSE.silero-vad`, diarizer `LICENSE`, and Qwen `LICENSE`.
   - I hashed 64 files of the installed pack (all under 50 MB, plus the GGUF) and all matched, with sizes matching. The installed and active pack is 0.1.1, `verify --full` returns `ready`, and the bundled `App/Resources/default-model-pack.json` equals `Models/Packs/amaranth-default-16gb-0.1.1.json`.
   - `verify-pack-offline.txt` was re-run for 0.1.1 under `sandbox-exec` with network denied: ASR WER 0.0%, 3 note items, 0 bad refs, injected claim not adopted, PASS.
5. **Live text: ADDRESSED, and it surfaces real work for T14.**
   - `live-sim.txt` is consistent with the table in `models/0001`:
     - 10 s / 8 s window: median 4.6 to 4.9 s, p95 8.5 s.
     - 6 s / 4 s window: median 2.8 to 2.9 s, p95 4.7 s.
   - It is an honest result: the latency gate (median < 5 s, p95 < 10 s) is reachable on the M2 Max.
   - Naive stitching costs 6 to 10 WER points on read speech and about 8 to 10 points on AMI (live 29.1% / 31.6% vs batch 21.0%), and 8 to 19% of provisional text is later revised.
   - The AMI runs also flag first-words and last-words as not OK for both configurations. The doc mentions only the final-window loss of the 6 s / 4 s read-speech run. T14 must handle both.
   - It was measured on files fed as if live. It was not measured under concurrent capture, and base-M2 is unverified. Both are stated.
   - The fallback decision (bounded re-decode with the same model, no second encoder, mark `questionableText`) is reasonable and consistent with the pack contents. It is untested; it is design only.
6. **E5RT: ACCEPTED as explained.** The doc says once per v2 process, never v3, and uncorrelated with the tail loss. That matches the `run.log` pattern I saw earlier (one message per v2 item). The origin is marked unverified, which is honest. v2 does not ship.
7. **Manual meeting-app, device and permission trials: still pending, correctly marked pending.** Not verifiable by me. This stays a gating item, not a Milestone-B entry blocker.

## Per-task status after fixes

- **T01:** MET (unchanged). `check.sh` is reported to pass; I independently ran `swift test` (72 passing). I did not re-run the app build or worker self-tests this time.
- **T02:** MET with caveats (no tuning vs held-out split, projected 16 GB, concatenated timing inputs, streaming now measured only in simulation). The caveats are now documented honestly.
- **T03:** MET for the automated gates. The meeting-app and device matrix is pending, honestly marked, and still the biggest outstanding capture risk.
- **T04:** MET. The earlier functional defect and the notice gap are closed.

## Remaining items (tracked, none blocking Milestone B entry)

Fix soon:
1. Correct the stale "int8v2 or v2 path as fallback" line in `models/0001` risk 2.
2. Run the manual meeting-app, device and permission-denial matrix before T10/T12 rely on capture. This is the user's pending scheduling.
3. T14: overlap alignment, a padded final-window flush, first-word handling, and measurement under concurrent capture.
4. Wire a `warmUp` into the app's installer (first-load Core ML compile of about 16 s currently falls on the first job).

Acceptable deferrals (unchanged): base-M2/16 GB and 8 GB qualification, the real-call held-out set and note-quality judging, DER and overlap handling (T07), Chrome testing, signing and notarization, release-mode 2 h/4 h soak, and re-verifying offline enforcement once the engines run in the XPC worker.
