# Capture 0001: Arbitrary-application audio capture design (T03)

Date: 2026-10-16 · Task: T03 · Status: Accepted for v0. The device/app matrix is partial; see the
[compatibility matrix](../../qualification/capture-matrix.md).

## Decision

**System output:** a private, **non-muting** Core Audio process tap
(`CATapDescription(stereoGlobalTapButExcludeProcesses:)`, `isPrivate = true`, `muteBehavior = .unmuted`) on a
private, tap-only aggregate device (`kAudioAggregateDeviceTapListKey`, drift compensation on, `TapAutoStart`).
The global tap does not depend on the output device. Switching the default output needs no rebuild (verified), so only a
change in the tap's own format triggers a rebuild into a new epoch.
Amaranth excludes itself in two ways: by its process object, and by bundle ID through the macOS 26
`CATapDescription.bundleIDs` property, which works before the app has a process object. That API is within our
26.5.2 floor. There is no virtual driver, no output-device replacement, no privileged helper and no private TCC SPI.
ScreenCaptureKit was **not** needed: the tap passed every trial below.

**Microphone:** a HAL IOProc directly on the selected input device (pinned by UID, or the current default). It never
changes the system default. A pinned device that disappears produces `deviceLost` and is retried every second.
Fallback to the default input happens only when the user's preference allows it.

**Realtime path (C, `Capture/RealtimeC`):** the IOProc `amr_ioproc` is C and is registered from C. It only copies frames
into a preallocated single-producer/single-consumer ring and updates atomic counters, including a callback-duration
histogram with 25 µs buckets. It does no allocation, takes no locks, and runs no Swift runtime, logging or I/O.
Overruns are counted and attached to the next chunk as `dropped_frames_before`, which the writer turns into an
explicit `overrun` gap.

**Format envelope:** float32 at 16, 22.05, 24, 32, 44.1, 48, 88.2 or 96 kHz, with 1–8 channels. Anything else
throws `unsupportedFormat` with a diagnostic and is never silently downscoped. Rings hold 2 s at 96 kHz for the
source's channel count: 1.5 MB for stereo and 6.1 MB at the worst case (8 channels).

**Writer:** a dedicated drain thread runs every 5 ms. A separate serial I/O queue commits each 2 s segment by writing a
self-written CAF file to staging, running `fsync`, closing it, renaming it atomically into
`audio/<source>/<minute>/<seq>.caf`, then appending a journal line (sha256 included). A journal line therefore never
names an uncommitted file. Full segments are exactly 2 s because chunks are split at segment boundaries.

**Timeline:** each source has its own epochs. The session time of epoch frame 0 comes from the IOProc host
timestamp. After that, time comes from sample counts using integer arithmetic.
- Device sample-time jumps become exact `gap` events, and the frame index advances by the jump, so later audio is not
  shifted.
- A sudden host-vs-sample clock jump of more than 250 ms between consecutive chunks (e.g. the device clock stalled)
  re-anchors a new epoch with a `clock.discontinuity` gap. Gradual drift is only reported: a 2000 ppm skew does not trip it.
- Device and format rebuilds start a new epoch, and the writer records the exact hole between epochs.
- Pause discards frames intentionally. It records a meeting-wide `pause` event and starts `resume` epochs, and it is
  not counted as missing audio.
- A source that starts late (e.g. while a permission prompt is open) gets a `source.startDelayed` gap from 0 s.

**Health:**
- A source that stops calling back for 1 s becomes `degraded`, with a `callbacks.stalled` fault. The 250 ms watchdog
  makes this visible in under 2 s.
- A source that never delivers audio within 3 s gets a `source.noAudio` fault.
- Silence is a status, never a fault.
- The session stays `preparing` until the first frame arrives, so "recording" is never shown while waiting for permission.
- An activity assertion (`.userInitiated` + `.idleSystemSleepDisabled`) is held while recording.

**Permissions:**
- Microphone uses `AVCaptureDevice` authorization and the normal prompt.
- System audio uses `NSAudioCaptureUsageDescription` and the normal prompt raised by the first tap.
  `SystemAudioPermissionProbe` verifies the grant using only public API: it makes a **muted** private tap of
  Amaranth's own process and plays a tone. A signal means granted; silent callbacks mean denied; no callbacks means
  the prompt is pending or the tap is unavailable.
- The `granted` result is verified. The `denied` result needs a manual trial (see the manual checklist).

## Evidence (M2 Max, macOS 26.5.2 25F84, Xcode 26.6, Debug build, ad-hoc signed)

| Gate | Result |
|---|---|
| First frames reach writer ≤ 2 s after permission | 45–80 ms (mic and system, runs 2–7 with permission already granted). **Run 1 (first launch, prompt open): system source 2.035 s → `gate: fail`**; the delay was the System Audio prompt, which the gate excludes ("after permission") |
| First segment committed ≤ 4 s | 2.05–2.08 s in runs 2–7 (one full 2 s segment). **Run 1: system 4.031 s (fail, prompt open).** From app launch on a first run, both limits are exceeded by however long the user takes to answer the prompts (66 s in one run): tap creation and `AudioDeviceStart` block until then. The session stays `preparing` (never shows "recording") and records `source.startDelayed` |
| Mic and system both present and distinct | External tones in the system track at −10.5 dBFS (the generator's 0.3 amplitude = −10.46 dBFS). The mic picks them up acoustically at −35 to −45 dBFS. |
| Self playback excluded | Amaranth's own 660 Hz tone: −240 dB in the system track (absent), present in the mic acoustically |
| New process after start captured | `afplay` launched mid-recording captured at −10.5 dBFS |
| Browser subprocess capture | Firefox 136 Web Audio tone captured at −14.0 dBFS (page gain 0.2 = −13.98) |
| No mute or route change | Default output and input UIDs unchanged; tap is `.unmuted` |
| Callback cost | p99 ≤ 25 µs (histogram resolution), max 9 µs observed, against a 10.67 ms buffer (512 frames at 48 kHz): about 0.2% |
| 30 min loaded capture (6 busy cores) | 0 overruns, 0 discontinuity events, callback p99 ≤ 25 µs (max 34 µs), CPU 6.45 % of one core, peak footprint 11.9 MiB (flat), max commit latency 18.7 ms |
| Route changes | Output → virtual device and back: no gap, tones captured throughout. Input → 44.1 kHz stereo and back: new epochs, 61–69 ms explicit gaps, recovery ≤ 58 ms (gate 5 s) |

Unit tests (`swift test --filter CaptureTests`, 18 tests) cover: ring round trip, splitting, overrun accounting,
interleaving of non-interleaved input, channel mismatch, CAF round trip and `afinfo` compatibility, contiguous
sample-exact segments, journal and staging hygiene, separate source formats, sample-time-jump gaps, pause epochs,
stall detection in under 2 s, clock discontinuity re-anchoring, drift tolerance, delayed-start gaps, and meters.

## Known limits / follow-ups
- Starting capture blocks while a TCC prompt is open. Callers (the T10 UI) must start the session off the main thread.
- A real meeting-app matrix (Zoom, Teams, Meet, Slack) and physical device trials (headphones, Bluetooth, USB) are
  pending the manual session.
- Chrome 119 on this machine crashes at launch on macOS 26, so Chrome is **untested** until it is updated.
- Base-M2 performance is unverified (the hardware isn't available).
- Durable SQLite indexing, crash recovery, disk projections and sleep handling are T05.
