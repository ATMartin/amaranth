# Hands-on UI checklist (T10/T11, needs a person)

Use the Debug app: `build/DerivedData/Build/Products/Debug/Amaranth.app`.

1. First launch shows onboarding. **Get Started** dismisses it and it does not return.
2. Record a short call (any app playing audio, plus your voice).
   - macOS asks for microphone and system-audio permission at the first Record, not before.
   - Both meters move. The menu-bar icon turns red and shows the elapsed time.
3. Pause, then Resume.
   - The label says nothing is being recorded while paused.
   - After processing, the Recording tab shows the pause.
4. Unplug or switch the microphone mid-recording. The mic row shows "Interrupted — gap marked" and the system row keeps going.
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
15. Deny microphone permission in System Settings, then Record. The recorder shows "Permission denied" with Open Privacy Settings….
16. VoiceOver: move through the recorder, the library and a transcript row; the labels are spoken.
17. Type in Your notes and switch to another meeting within one second. Switch back: the text was saved. Repeat, quitting with ⌘Q within one second of typing.
18. Press Record, and while the macOS permission prompt is still open, choose Quit. The app quits cleanly without hanging.

## Milestone G (design review 2026-10-23)

19. Details toggle (T22): on a fresh install the Notes tab shows no time links under notes. Click ⓘ (right of the tab picker) or press ⌘D: the links appear and the icon fills. Quit and relaunch: the choice is kept. Right-click a note: "Show in Transcript" jumps to its row with Details on or off.
20. Your notes / Private scratchpad (T24): both start collapsed. With text saved, the collapsed header shows "· N words". Expand one, relaunch: it is still expanded. Type in Your notes and collapse it within one second; switch meeting and back: the text was saved. The "Use these private notes…" switch is inside the expanded scratchpad.
21. Transcript skim mode (T25): with Details off, a meeting with gaps shows thin orange hairlines instead of gap rows; hovering one shows "No transcript 00:20–00:35: …"; flags are icons only (hover for the meaning); no MIC/SYS badges. ⌘D shows today's full rendering. In both modes a Notes evidence jump lands on the right row, and VoiceOver reads each hairline.
22. Rename (T26): the meeting title in the header is plain text (no cursor, no focus on click or Tab). Right-click a meeting in the sidebar → Rename… (first item): the sheet is pre-filled; Save updates the card, the header and search (search for a word of the new title) at once. Saving an empty or spaces-only title keeps the old title.
23. Status glyph (T27): each sidebar card is two lines (title with one glyph on the right; "date · duration"). Hover each glyph: recording (red ●), processing (spinner, "Transcribing 42%"), queued while recording (hourglass), failed (red ⚠, "… failed — retry available"), processed (✓ "Processed · audio saved"), processed with missing audio (orange !, "… s of audio missing — see Recording tab"), audio deleted (trash). The header shows the same glyph; ⌘D shows both full badges instead. Retry Processing / Process buttons show in both modes. VoiceOver reads the tooltip text.
