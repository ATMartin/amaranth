# Amaranth 0.1.0: tester guide (developer build)

Amaranth records meetings on your Mac, both your microphone and the call audio. It then makes a transcript with
speakers and evidence-backed notes, **entirely on this Mac**. Nothing is uploaded.

> **This is a developer build.** It is ad-hoc signed and **not notarized**, so macOS will warn the first time you open
> it. Distribution qualification is incomplete. There is no automatic updater: updates are installed by hand, so an
> update can never interrupt a recording.

## Requirements
- An Apple silicon Mac (M2 or newer) running **macOS 26.5.2 or later**. Older systems show an "Unsupported Mac" screen.
- About 4 GB free for the optional model pack, plus about 2 GB per hour of recording (both sources, lossless at the devices' native
  quality).

## Install
1. Open the DMG and drag **Amaranth** to Applications.
2. The first time, right-click Amaranth and choose **Open**, then confirm. The build isn't notarized; this is
   expected.
3. A short welcome explains what stays local.

## Models (optional for recording)
Transcripts, speakers, notes and live text need a one-time model download (about 4 GB): **Settings → Models** or the
toolbar button. Downloads are verified by hash and size and activate only when complete. Until then, Amaranth records
normally ("record-only") and processes the audio once models are installed. You can also import a model pack folder
offline.

## Record
1. Type a title (optional), choose **Microphone + system audio**, and press **Record** (⇧⌘R).
2. The first time, macOS asks for the **microphone** and **system audio recording** permissions. Allow both. If you
   deny one, the recorder says so and offers **Open Privacy Settings…**.
3. While recording:
   - each source has its own meter and status;
   - the menu bar shows a red icon and the elapsed time;
   - live text appears a few seconds behind speech (provisional, no speakers);
   - you can type private notes in the scratchpad.
4. **Pause** (⇧⌘P) records nothing until Resume. **Stop and Save** (⇧⌘S) finishes. Closing the window keeps
   recording. Quitting asks first.
5. Tell participants you are recording.

## After the meeting
The meeting is processed in the background: preparing audio, transcribing, finding speakers, then writing notes. A
one-hour meeting takes about 10 minutes on an M2 Max (both sources, including notes); slower Macs take longer. Processing pauses while you record or
when the Mac is hot or low on memory, and the meeting shows why.

- **Transcript:**
  - Click a time to play from it (Space toggles).
  - Right-click a line to correct text or change its speaker.
  - Use the speaker bar to rename or merge speakers.
  - "Unknown speaker" and overlap markers are shown honestly, not guessed.
- **Notes:**
  - Press **ⓘ** (⌘D) to show where each item came from (time links), transcript gaps and flags; right-click an item
    for **Show in Transcript** in either mode.
  - Items marked **?** are only partly confirmed by the transcript.
  - If you edit speakers or text, the notes say they're out of date; press **Regenerate**.
  - **Your notes** are never changed by regeneration.
- **Search** (sidebar, ⌘K) covers titles, transcripts and notes.
- **Rename** a meeting by right-clicking it in the sidebar.

### Keyboard shortcuts

| Action | Shortcut |
|---|---|
| Record | ⌘⇧R |
| Pause / Resume | ⌘⇧P |
| Stop and save | ⌘⇧S |
| Notes / Transcript / Recording tab | ⌘1 / ⌘2 / ⌘3 |
| Show or hide details | ⌘D |
| Export Markdown | ⌘E |
| Search | ⌘K |
| Play / pause (Transcript tab) | Space |

## Export
**Export → Markdown / Plain Text / JSON** saves the transcript and notes with timestamps, speakers and gaps. Your
private scratchpad is **not** included. **Export → Original Audio…** copies the lossless audio segments plus a
manifest of times and gaps.

## Delete
- **Delete Audio Only** removes the recordings but keeps the text and notes searchable. Playback and re-transcription
  stop.
- **Delete Meeting** removes everything for that meeting, including search entries. Files you exported elsewhere are
  not affected. Neither can be undone.

## If something goes wrong
- **The app or the Mac crashed while recording.** On next launch Amaranth recovers everything saved up to the crash,
  about the last second or two may be lost, and the meeting is marked "Interrupted". Nothing is lost silently: gaps
  are shown in the Recording tab.
- **The disk is nearly full.** Amaranth warns, then stops and saves before the disk fills. It never deletes earlier
  recordings.
- **Processing failed.** The meeting shows "failed — retry available". Press **Retry Processing**. The audio is
  always kept.
- **Model files are damaged.** Settings → Models shows it and offers reinstall or import. Recording still works.
- **Where the data lives:** `~/Library/Application Support/Amaranth/` (readable only by your user account).

## What has been tested
| Area | Tested on | Status |
|---|---|---|
| Capture, recovery, processing, notes, UI rendering | M2 Max, 96 GB, macOS 26.5.2 | Automated tests and self-tests pass |
| Meeting apps (Zoom, Teams, Meet, Slack), Bluetooth/USB devices, sleep/lock | — | **Not yet tested by a person** |
| Base M2 / 16 GB | — | **Unverified** (no hardware) |
| M2 / 8 GB | — | **Unverified; not supported** |

## Known limitations
- Transcripts are English-first. Other languages are not detected or flagged.
- Speaker separation misses some overlapping speech. Expect to rename and fix speakers.
- Notes come from a small local model. Many items are marked uncertain; check important ones against the cited lines.
- On base M2 Macs, notes for long meetings may take longer than 20 minutes (unmeasured).
- Live text is provisional; the final transcript replaces it after processing.
