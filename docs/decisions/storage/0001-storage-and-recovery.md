# Storage 0001: Durable recordings and recovery (T05)

Date: 2026-10-16 · Task: T05 · Status: Accepted for v0.

## Decision

**Audio on disk.** Each source is written as independent **2-second PCM CAF segments**, sharded per session-minute:
`audio/<source>/<minute:04>/<seq:08>.caf`. A segment is written to staging, `fsync`ed, then atomically renamed into
the committed set. Only then is its index entry published.
Each committed file is **self-describing**: it carries an `info` chunk with key `amaranth.segment` (meeting, source,
epoch, sequence, first frame in epoch, frame count, session interval, observed start). Recovery can therefore
rebuild the index from files alone. Every segment records its SHA-256 and exact sample count.

**Journal.** `journal.jsonl` holds one typed `JournalEntry` per line: segment, epoch or event (pause/resume, sleep,
gap, device/format change, disk, commit failure). A torn final line is tolerated. The journal is a redundant record;
files remain the source of truth for audio.

**Index.** SQLite (`amaranth.sqlite`, mode 0600; data folders 0700) has schema v1 with every plan §9 table. All writes
go through one serial writer queue (`MeetingStore.withDB`). The `SegmentIndexer` batches segment inserts off the
capture path and flushes on stop. Inserts are idempotent, so recovery replays are safe. A newer schema is refused,
not downgraded.

**Timeline.** Sample counts are authoritative within an epoch. Every discontinuity becomes an explicit event and
gap: a pause, sleep/wake, a device or format rebuild, a sample-time jump, a failed commit, or a missed callback window.
`TimelineNormalizer` maps epoch sample time to session time using the observed host-time slope. Raw sample-count drift
over two hours at 60× replay was 330 ms; after normalization it was 0.0 ms at the alignment markers (gate < 100 ms).

**Recovery** (`Capture/Recovery/SegmentRecovery.swift`, run at launch):
1. Index committed files that have no index row, using the file's own metadata. The journal is not required.
2. Quarantine truncated or corrupt committed files, never delete them, and report them.
3. Salvage interrupted staging writes down to whole frames.
4. Replay journal events.
5. Mark meetings that were recording as `interrupted`, so they are visible and resumable.

Recovery never presents missing audio as recorded silence.

**Safety policies in `RecordingSession`:**
- **Disk:** reserve 1 GiB. Warn when less than 15 minutes of projected recording time or less than 2 GiB remains.
  When the reserve is reached, stop and save (`stoppedForDiskSpace`); earlier recordings are never deleted.
- **Commit watchdog:** a stalled writer raises a fault, and failed commits become explicit gaps.
- **Callback watchdog:** stalled callbacks fault within 2 s.
- **Sleep:** `willSleep` interrupts the session, and resuming starts new `wake` epochs.
- **Microphone:** pinned by UID or following the default input. The app never changes the system default
  (capture/0001).

## Evidence

All of the following are in `swift test` (122 tests pass; `scripts/check.sh` → `ALL AUTOMATED CHECKS PASSED`). Printed
metrics are in [`evidence/2026-10-16/swift-test-metrics.txt`](../../qualification/evidence/2026-10-16/swift-test-metrics.txt).

| Acceptance (T05) | Test / evidence | Result |
|---|---|---|
| Random force-kill recovers every committed segment, ≤ 5 s tail loss under load | `ForceKillTests.randomKillsUnderLoadRecoverEverythingWithBoundedTailLoss` (`Tests/Capture/ForceKillTests.swift`). A child recorder process (`Tests/RecoveryChild`, a synthetic two-source sine signal) is SIGKILLed 5 times at random 3–9 s into recording. Four busy-spin CPU threads run alongside. | All committed segments recovered, 0 quarantined. Worst tail loss across runs is 1.27–1.90 s (the independent validator measured 1.78 s). Loss is bounded by construction: one 2 s segment plus staging. **Load caveat:** a light synthetic load. No kills land during minute-shard rollover, during long recordings, or while real inference runs; that is T12. |
| Healthy input persists while the other source disconnects; affected interval visible | `healthySourceContinuesWhileOtherDisconnects` | Pass: a fault event covers the interval, and the other source has no gap |
| Two-hour capture: no PCM accumulation, drift < 100 ms after normalization | `[long]` test (2 h at 60× replay, 7 224 segments, **synthetic clock**) | Growth from minute 15 to the end stays under the test's 50 MiB assertion; a PCM leak would be about 1 GB. Measured values were −62.7 MiB here and −420 MiB in the validator's run, so the footprint is noisy because models from other suites share the process. Normalized marker error is 0.0 ms against raw drift of 330 ms. **Caveat:** the synthetic host clock is jitter-free, and the normalizer inverts the same drift model the source generates. This shows the normalizer is correct, not real-device drift; that is T12. |
| Low disk saves a playable partial meeting, earlier recordings kept | `lowDiskWarnsThenStopsAndSavesWithoutDeletingAudio` | Pass |
| Index loss / no journal / truncated file / staging write / torn journal | `rebuildsLostIndexFromFilesAndJournal`, `indexesSelfDescribingFilesEvenWithoutJournal`, `truncatedCommittedFileIsQuarantinedAndReported`, `interruptedStagingWriteIsSalvagedToWholeFrames`, `tornJournalLineIsTolerated` | Pass |
| Sleep / interrupted stop / failed commits | `sleepInterruptsAndExplicitResumeStartsWakeEpochs`, `stoppingWhileInterruptedSealsTheSession`, `failedCommitsBecomeExplicitGapsNeverSilentLoss` | Pass |
| Callback p99 and memory gates | Milestone A: 30-minute loaded soak, `evidence/2026-10-16/capture-soak-30min.jsonl` (p99 and footprint per capture/0001) | Pass on M2 Max; base-M2/16 GB **unverified** |

## Limits

- Durability is `fsync` per segment. It does not protect against hardware power loss or filesystem failure (plan §10).
- The two-hour test runs at 60× replay through the real writer and recovery code with synthetic sources. A real
  two-hour hardware capture is part of T12 qualification.
- The data folder is enforced to 0700 at every launch, not only on creation. The abandoned earlier app's files that
  were in it were removed with the user's approval on 2026-10-16.
