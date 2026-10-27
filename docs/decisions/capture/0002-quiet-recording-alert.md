# capture/0002 — "Still recording?" alert after the meeting goes quiet

Date: 2026-10-27 · Status: **Accepted and implemented (T68)**, Fixes group before J. Amended the same day: no Restore
(the quiet tail is deleted), and the one notification prompt comes after the first Stop.

## Problem

The user starts a recording, the call ends, and the recording keeps running unnoticed for 10+ minutes, delaying
Stop and the notes. Goal: make sure each meeting is wrapped up and its notes generated promptly.

## Why not "stop when the call's stream disconnects"

The system source is a global tap (`CATapDescription(stereoGlobalTapButExcludeProcesses:)`, all processes except
Amaranth), not a per-app stream: when the call ends it keeps delivering audio (silence, or whatever plays next), so
there is nothing to observe disconnecting.

## Signals

1. **Quiet:** no new live-text words from either source (microphone or system) for the threshold (default 60 s).
   Live words, not levels: room noise, hum and music rarely produce words, so they don't hold the alert off the way
   an RMS threshold would. Both sources must be quiet; one side quiet alone is normal (listening or presenting).
   If live text is off or paused under pressure, fall back to the per-source RMS meters (`SourceMeter`, the existing
   `.silent` rule at −70 dBFS); the fallback is noted in the alert's diagnostics.
2. **Call app let go of the microphone:** some other process used audio input earlier in this recording
   (`kAudioHardwarePropertyProcessObjectList` + `kAudioProcessPropertyIsRunningInput`, Amaranth and its worker
   excluded) and none has for 30 s. This catches a call that ends while music then plays. Apps that keep the mic
   after a call (a browser tab left open, sometimes Teams) only make this signal late, never wrong; Signal 1 is the
   backstop. Polled at about 1 Hz off the realtime thread; nothing about other processes is stored.

Either signal raises the alert.

## Behaviour (user decisions, 2026-10-27)

- **Notify only. Never stops on its own.**
- Notification: "Still recording? No one has spoken for 1 min" (or "…the call seems to have ended" for Signal 2),
  with **Stop & Make Notes** and **Keep Recording**. In the app at the same time: the recording strip turns amber
  with the quiet time ("Quiet 1:12"), and the menu bar icon changes. The in-app signals work without notification
  permission.
- **Keep Recording** silences the alert until speech resumes on either side, then re-arms.
- **Trim the quiet tail when stopping:** stopping while the alert is active (from the notification, the strip's
  popover, the menu bar or Stop in the app) ends the meeting at the last live word + 5 s. **No Restore** (user,
  2026-10-27: "If you're trimming silence, there should be no effect on notes or transcript. Don't offer an option to
  restore a silent tail at all."), so the tail is deleted rather than hidden: its segment rows, capture events, files
  and journal lines go, and the duration shrinks. Whole 2 s segments are kept or dropped, so the meeting ends up to
  one segment after the cut. Order (rows, files, journal) means crash recovery can never bring the tail back once the
  trim finishes; a crash part-way leaves extra audio, never less. Nobody spoke at all → nothing is trimmed. Stopping
  while no alert is active, or after Keep Recording, trims nothing. The "Saved …" line says how much was removed.
- **Setting** (Settings → Recording, no code change needed): "Alert when a recording goes quiet" (on) and the
  threshold, 30 s to 5 min (default 60 s). The microphone-release signal shares the same toggle.
- **Notification permission:** the alert is on by default, so the ask comes once, right after the first recording
  ends (user, 2026-10-27), with a banner line saying why. Never at launch or during a recording (0006 rule). Turning
  the setting back on outside a recording also asks if still undecided. An earlier "Allow" for the T61 reminder covers
  it. Without permission, the amber strip and the menu bar icon still show the alert.
- Paused recordings never alert.

## Testing

- Table tests with a fake clock and fake word/mic-use feeds: 59 s vs 60 s, one side quiet only, speech resumes,
  Keep Recording re-arm, paused, live text off → meter fallback, mic released vs held.
- Trim tests: duration and processing range end at last word + 5 s; Restore brings the tail back; no alert → no trim.
- ui-render: amber strip at 900 and 1100 pt (nothing pushed into the toolbar overflow), the Settings row, the restore
  affordance.
- Hands-on checklist item: real call, hang up, alert within threshold + a few seconds.

## Implementation (T68)

- `Presentation/QuietAlert.swift`: `QuietMonitor`, the pure detector fed one input per 0.1 s recorder tick (session
  time, recording or not, live text running, newest live word end from `LiveTranscriptState.lastWordEnd`, every
  source below −70 dBFS RMS, other apps' microphone use). Words count once they end after the current quiet stretch
  began, so a word from before a pause can't reset it late. Paused, interrupted, starting and saving never alert, and
  the quiet time restarts on resume. A new word clears a raised alert. After Keep Recording, or after speech resumes
  following an alert, the call-ended signal needs an app to use the microphone again first, so it can't repeat while
  people keep talking in the room after the call. `QuietAlertSettings` holds the keys, default and bounds.
- `Capture/Devices/MicrophoneUse.swift`: `kAudioHardwarePropertyProcessObjectList` and
  `kAudioProcessPropertyIsRunningInput`, skipping this process and `com.alexmartin.amaranth*`. Polled at 1 Hz off the
  main thread while recording. Nil (unknown) never counts as released.
- `Capture/Recorder/CaptureTrim.swift` and `MeetingStore.trimCapture`: the trim above.
- App: `RecorderModel` (monitor, poll, `keepRecording()`, trim at `stop()`, the ask after Stop); the strip shows an
  amber "● Quiet 1:12" in place of the clock (the clock is in its tooltip and the menu bar). A click opens "Still
  recording?" with Keep Recording / Stop & Make Notes. While it shows, the calendar question shrinks to its icon:
  both didn't fit beside Stop at 900 pt. Menu bar: exclamation-mark icon, "Still recording? Quiet 1:12 — 1:02:03",
  Keep Recording and Stop & Make Notes. `QuietNotifications`: category with the two actions, routed through the T61
  notification delegate, one notification per recording (replaced, removed when it no longer applies). A late click
  for a recording that already ended does nothing.
- Tests: `Tests/UI/QuietMonitorTests` (59 vs 60 s, nobody spoke, one side talking, speech resumes, Keep Recording
  re-arm, paused, levels fallback, mic released / never used / held / unknown, call-ended re-arm, trim only while
  alerted, settings bounds) and `Tests/Capture/CaptureTrimTests` (whole-segment plan, rows/files/journal removed,
  recovery and a lost database don't bring the tail back). ui-render: the strip (quiet, call ended), the popover,
  Settings → Recording, and the on-screen toolbar at 1100/900 pt with the quiet strip, alone and with the calendar
  question, nothing in the overflow.
- Not verified here: the microphone-use signal with a real call app (it returns "no other app" on this Mac when
  idle). Hands-on checklist item 60.
