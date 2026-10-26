# Hands-on UI checklist (T10/T11, needs a person)

Use the Debug app: `build/DerivedData/Build/Products/Debug/Amaranth.app`.

1. First launch shows onboarding. **Get Started** dismisses it and it does not return.
2. Record a short call (any app playing audio, plus your voice).
   - macOS asks for microphone and system-audio permission at the first Record, not before.
   - The toolbar recording strip shows a red dot and the elapsed time, and a green mic and system-audio glyph (hover each: source, status, device, "Saved up to"). The menu-bar icon turns red and shows the elapsed time.
3. Pause, then Resume.
   - The label says nothing is being recorded while paused.
   - After processing, the Recording tab shows the pause.
4. Unplug or switch the microphone mid-recording. The mic glyph in the recording strip turns orange with the tooltip "Interrupted — gap marked", and the system glyph stays green.
5. Close the window while recording. Recording continues, and the menu bar can bring the window back.
6. Choose Quit while recording. The dialog offers Stop, Save and Quit or Keep Recording, and Stop saves.
7. After Stop the meeting is selected. Processing badges move through queued, transcribing and writing notes; Notes appear.
8. In Notes, click an evidence time. The Transcript tab opens with that row highlighted.
9. In Transcript:
   - Click a time; audio plays from there. Space toggles play and pause.
   - Rename a speaker. The rows update and the Notes tab shows "changed after these notes were made" with Regenerate.
   - Right-click a row, then Correct Text…. The row shows "edited", and the corrected text appears in search and exports.
10. Type in Your notes, then Regenerate. Your notes are unchanged.
11. Search for a word you said. The hit opens the meeting at that row.
12. Export Markdown. Check that timestamps, speakers and gaps are present and the private scratchpad is not.
13. Delete Audio Only. The dialog explains what stays. Afterwards playback says audio was deleted and search still finds the text.
14. Delete Meeting. It disappears and search finds nothing from it after relaunching the app.
15. Deny microphone permission in System Settings, then Record. The mic glyph turns red ("Permission denied — see System Settings"), and a red banner above the detail pane offers Open Privacy Settings….
16. VoiceOver: move through the toolbar Record button, the recording strip glyphs, the library and a transcript row; the labels are spoken.
17. Type in Your notes and switch to another meeting within one second. Switch back: the text was saved. Repeat, quitting with ⌘Q within one second of typing.
18. Press Record, and while the macOS permission prompt is still open, choose Quit. The app quits cleanly without hanging.

## Milestone G (design review 2026-10-23)

19. Details toggle (T22): on a fresh install the Notes tab shows no time links under notes. Click ⓘ (right of the tab picker) or press ⌘D: the links appear and the icon fills. Quit and relaunch: the choice is kept. Right-click a note: "Show in Transcript" jumps to its row with Details on or off.
20. Your notes / Private scratchpad (T24): both start collapsed. With text saved, the collapsed header shows "· N words". Expand one, relaunch: it is still expanded. Type in Your notes and collapse it within one second; switch meeting and back: the text was saved. The "Use these private notes…" switch is inside the expanded scratchpad.
21. Transcript skim mode (T25): with Details off, a meeting with gaps shows thin orange hairlines instead of gap rows; hovering one shows "No transcript 00:20–00:35: …"; flags are icons only (hover for the meaning); no MIC/SYS badges. ⌘D shows today's full rendering. In both modes a Notes evidence jump lands on the right row, and VoiceOver reads each hairline.
22. Rename (T26): the meeting title in the header is plain text (no cursor, no focus on click or Tab). Right-click a meeting in the sidebar → Rename… (first item): the sheet is pre-filled; Save updates the card, the header and search (search for a word of the new title) at once. Saving an empty or spaces-only title keeps the old title.
23. Status glyph (T27): each sidebar card is two lines (title with one glyph on the right; "date · duration"). Hover each glyph: recording (red ●), processing (spinner, "Transcribing 42%"), queued while recording (hourglass), failed (red ⚠, "… failed — retry available"), processed (✓ "Processed · audio saved"), processed with missing audio (orange !, "… s of audio missing — see Recording tab"), audio deleted (trash). The header shows the same glyph; ⌘D shows both full badges instead. Retry Processing / Process buttons show in both modes. VoiceOver reads the tooltip text.
24. Editable fields (T28), dark mode now (light mode in T44). For each field: click into it, check the focus indicator and the cursor, and save a screenshot to `docs/qualification/evidence/<date>/`.

    | Field | Where | Style | Placeholder | Focus ring visible | Cursor visible |
    |---|---|---|---|---|---|
    | Search | sidebar top | system search field | "Search transcripts and notes" | ☐ | ☐ |
    | Meeting title | Record ▾ options popover (T31) | rounded border | "Meeting — <date> <time>" | ☐ | ☐ |
    | Scratchpad while recording | live transcript view → Scratchpad (⌘⇧N) | rounded border | "Private scratchpad (only on this Mac)" | ☐ | ☐ |
    | Your notes | Notes tab (expand) | TextEditor + accent border when focused | "Write your own notes…" | ☐ | ☐ |
    | Private scratchpad | Notes tab (expand) | TextEditor + accent border when focused | "Private notes, only on this Mac…" | ☐ | ☐ |
    | Rename meeting / speaker, Correct text | sheets | system text field | the sheet title | ☐ | ☐ |

    Settings has no text fields (Settings → Recording has only pickers). No field uses `.textFieldStyle(.plain)` (the old plain header title field was removed in T26). The insertion point is the system one; on macOS 14+ it is drawn in the accent color. If it is hard to see, note which field.
25. Shortcuts and tooltips (T29), main window focused: ⌘1/⌘2/⌘3 switch tabs, ⌘D toggles Details, ⌘E opens the Markdown export panel, ⌘K puts the cursor in Search, ⌘⇧R/⌘⇧P/⌘⇧S record, pause and stop. The menu bar shows Meeting ▸ Notes/Transcript/Recording/Export Markdown…/Search Meetings and View ▸ Show Details. With a sheet open (Rename…, Correct Text…, models) none of ⌘1–⌘3, ⌘E, ⌘K acts. Hover: Record, Pause/Resume, Stop and Save, tab picker, ⓘ, Export, Delete, Retry/Process, Play each show a tooltip naming its shortcut where it has one. Check Xcode's console for "duplicate key equivalent" warnings (⌘E could clash with a system "Use Selection for Find" item in text fields).

## Milestone H (recorder simplification)

26. Recorder in the toolbar (T31): the sidebar is search and meetings only. The toolbar's leading group shows ● Record, a ▾ chevron and the Models button. Hover Record: "Record a new meeting (⌘⇧R). Amaranth records only when you press Record; let participants know." One click on Record (or ⌘⇧R) starts recording with the Settings → Recording defaults and a title "Meeting — <date> <time>"; the live transcript shows in the detail pane. The ▾ popover has Title, Record (sources), Microphone (this meeting only), Recording Settings… (opens Settings) and Record (Return); after that recording the next one uses the Settings defaults again. While recording, the strip replaces Record: ● elapsed · a glyph per source · Pause/Resume (⌘⇧P) · Stop and Save (⌘⇧S). After Stop, a dismissable banner above the detail pane says where the audio was saved. The menu bar still records and stops. Quit while recording still asks first.
27. Recording defaults (T30): in Settings → Recording, choose "Microphone only" and a USB microphone; press Record: only the mic is recorded with that device. Unplug the USB microphone and press Record: recording starts on the system default microphone and the banner says the chosen microphone isn't connected.
28. Default tabs (T32): press Record: the new meeting is selected and its live transcript is in front without clicks (also when started from the menu bar, which brings the window forward). Stop: the meeting stays selected on Transcript. When its notes arrive (models installed), the Notes tab shows once; if you picked a tab yourself after Stop, it stays. Opening a meeting with notes shows Notes; one without notes shows Transcript; a tab you picked for a meeting this session is kept when you come back to it.
29. Scratchpad while recording (T33): the live view has no scratchpad until you click Scratchpad (or press ⌘⇧N); hover it: "Private scratchpad for this meeting (⌘⇧N)". It opens inline above the live transcript (not a sheet), with the cursor in it when empty. Type, close it, reopen: the text is still there and is not selected. Close it: the live transcript is unobstructed. After Stop, the text is in the meeting's Private scratchpad (Notes tab). The open/closed state is kept for the next recording until you quit.
