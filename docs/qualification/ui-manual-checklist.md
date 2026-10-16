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
