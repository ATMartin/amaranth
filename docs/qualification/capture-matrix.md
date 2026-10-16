# Capture compatibility matrix (T03)

Host: Apple M2 Max (96 GB), macOS 26.5.2 (25F84), Xcode 26.6, Debug build, ad-hoc signed, bundle `com.alexmartin.amaranth`.
Each row was run through LaunchServices (`open -W -n Amaranth.app --args --self-test …`), so TCC attributes permissions
to Amaranth. **Untested ≠ supported.** Base-M2/16 GB and 8 GB are **unverified** (hardware unavailable).

## Automated, real hardware

| # | Trial | Source/route | Result | Evidence |
|---|---|---|---|---|
| 1 | External process tone (`afplay` 1 kHz) | System tap, built-in speakers | ✅ −10.5 dBFS (exact; generator is 0.3 = −10.46 dBFS) | `capture-signals`, runs 2–7. Run 1 (first launch) failed only the latency gate while the System Audio prompt was open (first frame 2.035 s, first commit 4.031 s); see `capture-signals-run1-first-permission.jsonl` |
| 2 | Process started **after** recording began (`afplay` 1.5 kHz) | System tap | ✅ −10.5 dBFS | `capture-signals` |
| 3 | Amaranth's own playback (AVAudioPlayer 660 Hz) | System tap | ✅ excluded: −240 dB (absent); heard by the mic acoustically | `capture-signals` |
| 4 | Browser Web Audio, Firefox 136.0.2 (content subprocess) | System tap | ✅ −14.0 dBFS (page gain 0.2 = −13.98) | `Benchmarks/Capture/browser-matrix.sh` |
| 5 | Browser, Chrome 119.0.6045.123 | — | ⚠️ **untested**: Chrome 119 segfaults at launch on macOS 26 (browser problem, not capture) | browser-matrix.sh |
| 6 | Built-in mic, 48 kHz mono | HAL IOProc | ✅ live (room noise around −57 to −67 dBFS RMS), tones heard acoustically | `capture-signals` |
| 7 | Default output → virtual device (Microsoft Teams Audio) mid-recording, then back | System tap | ✅ capture continuous: −10.5 dBFS before, during and after; no epoch change or gap | `capture-routes` |
| 8 | Default input → ManyCam Virtual Mic (44.1 kHz stereo) mid-recording, then back | Mic follows default | ✅ new epochs 48k/1ch → 44.1k/2ch → 48k/1ch; explicit gaps of 69 ms and 61 ms; recovery 58 ms / 43 ms (gate: 5 s) | `capture-routes` |
| 9 | Default devices after the test | — | ✅ restored | `capture-routes` |
| 10 | Recording does not mute or reroute playback | — | ✅ default output and input UIDs unchanged; tap is `.unmuted` | `capture-signals` |
| 11 | System-audio permission probe (granted) | Muted self-tap | ✅ `granted` (signal within 512 frames) | `capture-signals` |
| 12 | 30 min loaded capture (6 busy cores) | Both | ✅ 0 overruns, 0 events, callback p99 ≤ 25 µs (max 34 µs) vs 10.67 ms buffer, CPU 6.45 %, peak footprint 11.9 MiB, max commit 18.7 ms, mic drift 3.4 ms | `Benchmarks/Capture/soak.sh 30 6` |

Observed behaviour to design around:
- While a TCC prompt is pending, the tap delivers **no callbacks**, and `AudioDeviceStart` / tap creation **block the calling
  thread** until the user answers (one run measured 66 s). The session reports `source.startDelayed` and
  `source.noAudio` faults. **The UI must start capture off the main thread** (T10).
- With ad-hoc signing, a rebuild changes the code signature, so macOS shows the microphone prompt again and sometimes the
  system-audio prompt. A stable team signing identity fixes this.

## Manual (needs a person)

See [capture-manual-checklist.md](capture-manual-checklist.md): Zoom 7.0.6, Teams, Meet (Chrome/Safari), Slack 4.52.178
huddles; wired, Bluetooth and USB devices; lock/sleep; microphone or system-audio **denial** and revocation.
All of these are **pending**.

## Format envelope

Supported: float32 at 16/22.05/24/32/44.1/48/88.2/96 kHz with 1–8 channels. Anything else gives an `unsupportedFormat`
diagnostic (format logged in the source diagnostics). Ring memory: 2 s at 96 kHz × channels × 4 B, which is
1.5 MB for stereo and 6.1 MB at 8 channels.
