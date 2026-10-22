# Live 0001: Provisional live text while recording (T14, promoted by the user)

Date: 2026-10-16 · Task: T14 · Status: Accepted for v0. The latency gate is met on the M2 Max with synthetic replay.
**Real calls and base-M2 hardware are unverified.**

## Decision

**Only durable audio.**
- Every 2 s, `LiveTextModel` (in the app) takes the recording session's committed segments, the same files T05
  recovers. It sends one source's new segments to the XPC worker as a `LiveRequest`, with one request in flight and
  the source furthest behind going first.
- Capture never waits on live text, and live text never reads the realtime ring.

**Stateless worker passes** (`ASR/Live/LiveTranscriber.swift`).
- Each request carries the source's *stable point* and the committed segments from 2.5 s before it, so a worker crash
  or recycle loses nothing: the next tick resends.
- The worker decodes the CAF segments, downmixes anti-phase-safely, resamples to 16 kHz, and transcribes from the
  stable point in single passes of at most 14.9 s with 2 s of left context. It never uses FluidAudio's long path.
- Words before the last pause of at least 0.4 s that ends at least 1.5 s before the newest audio become **stable**.
  Later words are **tentative** and are replaced next pass. After 10 s without a pause, the stable point is forced to
  a word boundary 2 s back, so latency stays bounded.
- A backlog (after pressure) is processed in several single-pass windows within one request.

**Under-yield guard.** Parakeet's span skipping (asr/0001 defect 2) also hits live windows. A catch-up pass under
simulated pressure lost two whole stretches (mic WER 20.8%).
- Live text now detects likely speech from frame energy (100 ms frames, adaptive floor).
- When at least 2 s of speech has no word nearby, it re-decodes with other contexts, then as two halves, and keeps the
  best-covered result. It never invents text.
- With the guard, the same run scores 1.8%.

**Pressure.** Under serious or critical thermal state (or any `pauseReason`), live text pauses with a visible
message ("Live text paused… recording continues") and catches up afterwards. Every captured segment is kept either
way.

**Presentation.**
- While recording, the detail pane shows **Live text — provisional**: source tags (MIC/SYS), no guessed speakers,
  dimmed italic tentative words, and "about N s behind".
- At Stop, the live words are published as a `.provisional` revision (`publishTranscript(provisional: true)`). Until
  the final transcript exists, the meeting shows it with a banner, and **edits and notes are disabled**.
- The final pipeline then produces the real transcript with speakers, replacing it in place. User edits only ever
  apply to final revisions, so the live-to-final transition cannot lose them.

**Not reused.** The plan suggests reusing finalized live chunks after Stop. v0 re-runs the full pipeline instead,
because live passes use energy rather than VAD and no 2 s right context, so final quality would drop. The reuse is
deferred until it can be shown not to cost accuracy.

## Measurements (M2 Max; `Amaranth --self-test live-latency|live-pressure --repo <repo>`)

The replay runs in real time: mic is 10 LibriSpeech utterances (~124 s); system audio is the first 120 s of AMI
EN2002a (four speakers, heavy overlap). Live text runs through the real XPC worker and installed pack. Evidence:
`evidence/2026-10-16/selftest-live-*.jsonl`.

| Gate (T14) | live-latency | live-pressure (15 s simulated thermal pause) |
|---|---|---|
| Median provisional-text delay < 5 s | **2.18 s** (2.13 s in an earlier run) | 2.55 s |
| p95 < 10 s | **4.99 s** (5.15 s) | 11.3 s: gate not applicable during a pause (by design, words spoken during the pause wait for it to end; the self-test does not check p95) |
| Provisional mic WER | 2.4% | 1.8% |
| Capture: missing-audio events / ring overruns | 0 / 0 | 0 / 0 |
| Peak footprint: app / worker | 91 / 45 MiB | 90 / 43 MiB |
| Live text paused and caught up to the end | – | yes (processed to 122–124 s of 124 s) |

Unit tests:
- `liveTranscriberSettlesWordsIncrementally` runs with and without a 16 s backlog, on 48 kHz stereo device-like
  input resampled live: 2.1% WER, words in time order, no re-emission.
- `LiveTranscriptStateTests` covers stable/tentative merging, ignoring stale responses, one latency sample per word,
  and a valid provisional revision.

## Acceptance (T14)

| Criterion | Status |
|---|---|
| Median < 5 s and p95 < 10 s on the reference machine, on a representative measured session set | Met on M2 Max with synthetic replays. A *representative real session set* and the **base-M2 reference are unverified**. |
| Simultaneous call plus live inference meets capture loss, memory and thermal gates | Met for synthetic sources: zero loss, zero overruns, app 91 MiB. A real call with a real meeting app is part of the manual capture checklist. |
| Live/final transitions preserve user edits and show uncertainty | Met: edits are disabled on provisional text, there are no live speakers, and banners mark it provisional |
| T12 and T13 validate T14 | Pending (Milestone F, release qualification; decision 0004) |
