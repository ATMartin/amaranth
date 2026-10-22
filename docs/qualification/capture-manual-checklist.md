# Capture manual trials (T03)

These trials need a person: real calls, physical devices, or a deliberate permission denial. Each trial runs
`capture-tone` or `capture-signals` under the real app identity, so results are recorded as JSON.
Record the app version for every row. If a trial can't be run, mark it **untested**, never as supported.

Helper (records 20 s of both sources; the person speaks while the remote side plays or speaks):

```sh
APP=build/DerivedData/Build/Products/Debug/Amaranth.app
open -W -n "$APP" --args --self-test capture-tone --hz 1234 --seconds 20 --sources both \
  --label "<trial>" --self-test-output /tmp/amaranth-<trial>.jsonl; tail -2 /tmp/amaranth-<trial>.jsonl
```

During each call trial, have the remote side play the 1234 Hz page (`Benchmarks/Capture/tone.html`, click
Play) or speak. Pass criteria: system track tone `windowsWithTone > 0` (or audible remote speech in the
segments), mic RMS above −70 dBFS while you talk, no `missingAudioEvents`, and the call's audio isn't
muted or rerouted for you.

## Meeting apps (no meeting APIs used)

| Trial | App + version | Route | Result | Notes |
|---|---|---|---|---|
| Zoom call, remote speaks/plays tone | zoom.us 7.0.6 | built-in speakers | | |
| Microsoft Teams call | | built-in | | |
| Google Meet in Chrome | Chrome (current, 119 crashes on macOS 26) | built-in | | |
| Google Meet in Safari | Safari 26.5.2 | built-in | | |
| Slack huddle | Slack 4.52.178 | built-in | | |
| Local audio player (a recording played by the user) | not recorded | built-in output | **Pass (Debug build, local player only)** (2026-10-22) | System track captured to the end; start delays came from the open permission prompt and manual playback start and were shown as gaps. No missing audio after start. Live text ran (5 provisional revisions). `evidence/2026-10-22/first-real-meeting.json` |
| Meeting app launched after recording started | any | built-in | | |
| Mute/unmute in the meeting app mid-recording | any | built-in | | |

## Devices and routes

| Trial | Device | Result | Notes |
|---|---|---|---|
| Wired headphones plugged in mid-recording | | | Output route change → expect `deviceChange`, continued capture |
| Bluetooth headset (A2DP→HFP switch when the call starts) | | | Format change → new epoch, explicit gap |
| USB microphone pinned, then unplugged | | | Pinned mic loss visible within 2 s; no silent fallback unless enabled |
| USB microphone re-plugged | | | Resume within 5 s |
| Lock screen (no sleep) for 1 min while recording | | | Capture continues |
| Lid close / sleep while recording | | | Interrupted session, explicit resume on wake |

## Permissions

| Trial | Steps | Result |
|---|---|---|
| Microphone denied | System Settings › Privacy › Microphone › turn Amaranth off, run `capture-signals` | Expect mic `permissionDenied` event, system capture still records |
| System audio denied | `tccutil reset AudioCapture com.alexmartin.amaranth`, run `capture-signals`, click **Don't Allow** | Expect probe `denied`, no false "recording" claim for system audio |
| Revoke mid-recording | Start a 60 s `capture-tone`, toggle mic permission off at 20 s | Expect visible fault, no silent data loss |

## Live text (T14), with a real call
- During a real Zoom/Meet/Teams call with Live text showing: the text appears a few seconds behind speech, and "about N s behind" stays under 5 s.
- The call audio has no glitches, and the meeting's Recording tab shows no gaps afterwards.
- After Stop, the meeting shows "Live text (provisional)" until processing finishes, then the final transcript with speakers.
