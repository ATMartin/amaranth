# Milestone H — recorder simplification: result notes (2026-10-25)

Tasks T30–T34, one commit each on main. Decisions for this run (user, 2026-10-25): T21 on hold; capture self-test
run once on the final build; the Sonnet validator automates the hands-on recorder pass.

## T30 Recording defaults in Settings
- Settings → Recording → "New recordings": Record (sources) and Microphone, stored under the existing keys
  `defaultSources` / `microphoneUID` (pinned by `RecordingDefaultsTests`). `RecorderModel.start()` no longer writes them.
- Per-recording choices follow the defaults until changed for one meeting (`customized`) and reset after each recording.
- A saved microphone that isn't connected → System default for that recording plus a one-line banner notice.

## T31 Toolbar Record control, recording strip, banner
- Fallback used: Record button + adjacent chevron opening a **popover**, not a menu (a toolbar Menu cannot hold the
  Title field). A ControlGroup in the toolbar was moved to the trailing edge and truncated by macOS 26, so the
  control is an HStack of two buttons in one leading toolbar item, before Models.
- Automatic title "Meeting — Oct 25, 2026 10:06 PM" when the title is blank (time follows the user's 12/24 h setting).
- Strip shows while a session is open, *including* "interrupted by sleep" (before this, an interrupted recording had
  no Resume in the window or the menu bar; `RecorderModel.inSession` fixes both).

## T32 Default tabs
- `DetailTabRules.defaultTab` / `MeetingDetail.defaultTab(isRecording:)` and `NotesArrivalSwitch` (Presentation, unit
  tested). Tab choices count as the user's for that meeting for the session; the automatic Notes switch has no
  Settings toggle (fallback not needed so far).

## T33 Scratchpad button
- Scratchpad toggle (⌘⇧N) in the live view header; inline editor above the live transcript; closed by default, open
  state kept for the session (not persisted). Saving goes through `RecordingScratchpad.save` (tested end to end).

## T34 Health popover — where everything from the old sidebar RecorderPanel went

| Old RecorderPanel item | New home |
|---|---|
| Title field | Record ▾ popover (blank → automatic title) |
| Sources / Microphone pickers | Settings → Recording (defaults) and Record ▾ popover (this meeting) |
| Record button, ⌘⇧R | Toolbar Record |
| Status line (Recording · elapsed, Paused, Interrupted, Starting…, Saving…) | Recording strip |
| Pause/Resume ⌘⇧P, Stop and Save ⌘⇧S | Recording strip |
| Per-source meters | Health popover (click the strip glyphs) |
| Per-source status text, "saving delayed" | Glyph colour + tooltip; health popover |
| Device name, "Saved up to" | Glyph tooltip; health popover |
| Open Privacy Settings… | Red banner above the detail pane |
| Low-disk warning | Orange strip glyph + tooltip; health popover |
| Private scratchpad | Live view → Scratchpad (⌘⇧N) |
| Consent sentence | Record tooltips (toolbar and popover) and onboarding |
| "Saved N segments … to <folder>" | Banner after Stop; during recording the folder is in the health popover |
| Recovery message, errors | Banner (errors red), dismissable |

- Meter polling: unchanged at 10 Hz for the whole recording, because the strip glyphs need it too.
- The popover lists the meeting folder, not a live segment count: counting segments needs a full session snapshot on
  every tick. The count still appears in the banner after Stop.

## Capture self-test (final build, 2026-10-25)

`--self-test capture-signals` was run three times on the final H build. Evidence is in `evidence/2026-10-25/`. Run 3 was
done with no other Amaranth running and the machine idle. All three runs fail on one condition only: a
`gap:source.startDelayed` event, because system audio delivers its first frame at 1.21–1.28 s, and the gap threshold is
0.5 s. Everything else passes: the latency gates for both sources, the microphone signal, external audio captured,
Amaranth's own audio excluded, and default routes unchanged.

Not caused by Milestone H:
- No capture file has changed since `6ac994e` (2026-10-16), whose runs 2–7 passed with the system first frame at
  0.05–0.08 s. That includes `Capture/`, `Domain/Capture/` and `App/Launch/CaptureSelfTest.swift`.
- macOS 27.0.1 was installed on 2026-10-20, between the passing runs and these runs.
- The gap event is working as designed: about 1.2 s of system-audio lead-in really is lost, and the recording says so.

Resolved 2026-10-26 (separate commit; see below).

## System tap start fix (2026-10-26)

Cause: on macOS 27.0.1, a tap-only aggregate device created with `kAudioAggregateDeviceTapAutoStartKey: true` doesn't
call the IOProc until another process plays sound. The capture self-test starts `afplay` 1.0 s after Record, so the first
system frame came at about 1.2 s. In a real meeting, the system track started at the first remote sound, and the silence
before it was reported as a `source.startDelayed` gap. No audio was lost, but the meeting was flagged as having gaps.
Setup is not slow: the tap, aggregate and device start take 17 ms in total.

Evidence (`evidence/2026-10-26/`):
- `tap-startup-variants.jsonl`, a temporary experiment: device start → first callback with nothing playing. Auto-start
  off took 41 ms. Every other variant had no callback within 3 s: the current setup, without the bundle-ID exclusion,
  without drift compensation, clocked from the output device, pre-created 1.5 s ahead, with Amaranth playing silence, or
  a self-process tap.
- Fix: `kAudioAggregateDeviceTapAutoStartKey: false` in `SystemAudioTapSource`.
  `capture-signals-autostart-off-run1..3.jsonl` all pass: system first frame at 0.039, 0.071 and 0.071 s, no events,
  external audio captured, Amaranth's own audio excluded, routes unchanged. `scripts/check.sh` passes.
- Not re-run: `capture-routes`, which switches default devices. The route path reopens through the same `open()`.

## Validation (2026-10-25)

The Sonnet validator gave a PASS with no blocking findings (`milestone-h-verdict-v1.md`). It raised three should-fix
items, all fixed in the follow-up commit:
1. `RecorderModel.start()` now refuses while a session is starting (`!inSession`), so pressing Return in the popover's
   Title field can't start two recordings.
2. Quit asks first, and the menu-bar icon stays red, while a recording is interrupted by sleep (`inSession`).
3. Resume after an interruption restarts the sources off the main thread, guarded against a double Resume.

The Settings copy now names the ▾ button instead of a "Record menu". These are left as notes: a title typed in the
popover and then abandoned carries over to the next one-click Record; a tab picked during recording gives way to
Transcript at Stop; the tab tests cover the rules but not the `LibraryModel` wiring.
The rebuild means macOS asks for microphone and system-audio permission again at the next Record.
