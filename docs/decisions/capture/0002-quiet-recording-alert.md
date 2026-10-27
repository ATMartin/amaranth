# capture/0002 — "Still recording?" alert after the meeting goes quiet

Date: 2026-10-27 · Status: **Accepted (user decisions below); not implemented** (task T68, Fixes group before J).

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
- **Trim the quiet tail when stopping:** stopping while the alert is active (from the notification, or Stop in the
  app) ends the meeting at the last live word + 5 s. The trim is non-destructive: the tail audio stays on disk, is
  excluded from transcription, notes, playback and duration, and the meeting offers "Restore N min trimmed audio" so
  speech the live text missed is never lost. Stopping while no alert is active trims nothing.
- **Setting** (Settings → Recording, no code change needed): "Alert when a recording goes quiet" (on) and the
  threshold, 30 s to 5 min (default 60 s). Turning it on asks for notification permission if not decided yet; never
  asked during a recording (0006 rule). The microphone-release signal shares the same toggle.
- Paused recordings never alert.

## Testing

- Table tests with a fake clock and fake word/mic-use feeds: 59 s vs 60 s, one side quiet only, speech resumes,
  Keep Recording re-arm, paused, live text off → meter fallback, mic released vs held.
- Trim tests: duration and processing range end at last word + 5 s; Restore brings the tail back; no alert → no trim.
- ui-render: amber strip at 900 and 1100 pt (nothing pushed into the toolbar overflow), the Settings row, the restore
  affordance.
- Hands-on checklist item: real call, hang up, alert within threshold + a few seconds.
