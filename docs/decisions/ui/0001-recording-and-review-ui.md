# UI 0001: Native recording and review interface (T10)

Date: 2026-10-16 · Task: T10 · Status: Accepted for v0. It is verified by unit tests, an offscreen render self-test and
code review. **No person has used it interactively yet.** Hands-on checks are in the manual checklist (tracked item 17).

## Decision

**Structure.** SwiftUI on macOS 26, with three scenes:
- a main `Window`: a library sidebar holding the recorder panel, search, and meeting detail;
- a `MenuBarExtra`: always present, red while recording, with pause, resume and stop;
- `Settings`: Models, and Recording with the microphone mode.

All presentation logic that can be tested lives in the package module **`Presentation`**: transcript rows, gap rows,
speaker labels, edit composition, notes state, destructive-action wording, and detail/list loading. The SwiftUI views
stay thin.

**Recorder.**
- Choose the title, sources and microphone.
- Independent per-source meters and health, polled at **10 Hz from session snapshots**. Audio callbacks never publish
  to SwiftUI.
- "Saving delayed" appears when committed audio lags by more than 8 s. A low-disk warning shows projected minutes left.
- Pause and resume. The pause label says "nothing is being recorded".
- A private scratchpad while recording, saved as a new revision about every 10 s and at Stop.
- Permission denial shows **Open Privacy Settings…**. A silent source reads "Silent (still recording)". A disconnected
  device reads "Interrupted — gap marked".

**Safe close and quit.** Closing the window keeps recording, and the menu bar shows it. Quitting while recording asks
"Stop, Save and Quit" or "Keep Recording". There is no Escape-to-discard anywhere.

**Library.** Each meeting shows its audio headline and processing headline separately: saved, saved with gaps,
interrupted or audio deleted; and queued (with the reason it is paused), stage percentage, or failed with retry.
Full-text search covers titles, transcripts, notes and the user's notes, with highlighted snippets. Clicking a
transcript hit jumps to that row.

**Meeting detail.** Notes, Transcript and Recording tabs.
- **Transcript:**
  - A virtualized `List` with one row per speaker run; gaps are rows of their own.
  - Click a time to play from it. Playback uses an `AVAudioEngine` player per source that schedules the original CAF
    segments 8 s ahead, so gaps stay silent in place and nothing loads a whole meeting. When audio was deleted or
    never recorded, playback is disabled and the reason is shown.
  - Row flags: overlap, uncertain speaker, probable echo, possibly garbled, edited.
  - Speaker bar: rename and merge.
  - Row context menu: correct text, assign to an existing, new or unknown speaker, mark as uncertain, play from here.
  - Edits go to the store as `UserEdit`s. Speaker edits re-run reconcile; text corrections apply at display time.
- **Notes:**
  - Generated notes with evidence time links that jump to and highlight the cited row.
  - Owner and due date shown as "not stated" when absent; an uncertainty marker on doubtful items; limitations behind
    a disclosure.
  - A state banner: none, queued or paused, generating %, failed with retry, stale with Regenerate, or regeneration
    failed while the previous notes are shown.
  - **Your notes**, which regeneration never touches. Saves debounce for 1 s per field and are flushed synchronously
    when switching meetings, closing the view, or quitting.
  - **Private scratchpad**, with an explicit "use these private notes when generating notes" switch.
- **Recording:** audio retention, disk use, sources, and every capture event (gaps, pauses, device and format
  changes, sleep and wake).

**Responsiveness.** Library and detail loads and every store or scheduler action run off the main thread. A
generation counter drops stale loads.

**Onboarding.** One sheet. It explains that everything stays local, that permissions are requested at the first
Record, that participants should be told, and that models are optional for recording.

## Evidence

| Acceptance (T10) | Evidence | Status |
|---|---|---|
| Start, stop and save without logs or the terminal | Recorder panel, menu bar and quit guard (code); the capture path is the T03/T05 one already proven | Met in code; **hands-on check pending** (checklist) |
| A two-hour transcript scrolls and edits responsively; meters don't publish every callback | `twoHourTranscriptBuildsAndLoadsQuickly`: 3,600 rows built in 0.12 s, the detail loaded from the store in 0.51 s, and **one text correction round trip** (store write, search reindex, detail reload) in 0.96 s, all in a debug build and off the main thread in the app. `ui-render` self-test: the 3,601-row transcript laid out and rendered in 0.52 s. Meters poll at 10 Hz. Loads run off the main thread. | Met on M2 Max (debug); base-M2 **unverified** |
| Permissions, silent sources, disconnected devices and failed processing have actionable states | Recorder health texts and the Open Privacy Settings button; processing badges; Retry Processing; notes banners | Met in code |
| UI fixtures and final integration agree on unknown speakers, unavailable playback, stale notes and explicit destructive actions | `PresentationIntegrationTests`: each fixture persisted through the real store renders identical rows; unknown speakers are labelled; gap rows match coverage; the audio headline matches; the playback-unavailable reason follows the audio state; the stale flag is computed by the store; destructive dialogs state what is removed, what stays and "cannot be undone" | Met |
| Keyboard access and a clear menu-bar status | ⇧⌘R record, ⇧⌘P pause/resume, ⇧⌘S stop, Space play/pause; accessibility labels on health rows and gaps; menu-bar icon and status line | Met in code; VoiceOver not audited |

`ui-render` self-test (`Amaranth --self-test ui-render --self-test-output <dir>`) builds the real views over a
temporary store holding the fixtures and a synthetic 2-hour meeting, and writes PNGs. Inspected captures:
- the library with independent audio and processing badges ("Writing notes failed — retry available", "Queued ·
  paused while recording");
- a stale-notes banner with Regenerate;
- evidence links, "Owner: not stated";
- a gap row, "Unknown speaker" rows, and disabled playback times for a meeting with no audio.

## Limits
- `ui-render` logs an AppKit warning: "reentrant operation in its NSTableView delegate". It is tracked (item 19) and
  will become an assert in a future macOS.
- No interactive human session yet: the recorder flow, drag and scroll feel, VoiceOver, and real playback over real
  recordings need a person (checklist).
- The microphone-mode setting applies to meetings processed after the next launch.
- Text corrections cannot span two segments; the UI only offers them per row.
