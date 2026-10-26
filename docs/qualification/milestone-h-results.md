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
