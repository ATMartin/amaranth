# Milestone Q end-to-end runs (T73, 2026-11-02)

On the development Mac (M2 Max, macOS 26.5.2), with the user's real library (10 meetings, schema v6; backed up
first to `~/Library/Application Support/Amaranth Backups/2026-11-02-before-milestone-q/`, with a `defaults export`).
Builds are published from a separate clean git worktree, because another session keeps uncommitted edits in the main
checkout (publish.sh refuses a dirty tree, and the stamp would mark builds "modified").
The real app was driven through the Accessibility API (System Events): toolbar buttons, the Amaranth menu and the
Software Update window's buttons, exactly as a click would.

## 1. GitHub, Release N → N+1 (124 → 125)

- `scripts/install-local.sh` installed Release 124 (99e2da3; stamped "modified" because of the other session's
  uncommitted docs). Release 125 (83ddbda) published with `scripts/publish.sh` → https://github.com/ATMartin/amaranth/releases/tag/build-125.
- Quit + reopen 124: the launch check put **Update Available** in the toolbar (help: "Amaranth 0.1.0 (125) is available
  (you have 0.1.0 (124))"), between Hide Sidebar and the sun/moon; the sun/moon and Hide Ask still end the toolbar.
- Clicking it opened Software Update: "A new build is available", You have 0.1.0 (124) Release 99e2da3, modified /
  Available 0.1.0 (125) Release 83ddbda, What's changed (commit subjects since build 122), "19.4 MB download".
- Install and Relaunch: `update.log` → `22:08:57 waiting for Amaranth (pid 72579) to quit`, `22:08:58 installed;
  relaunching`; the new process (`--updated-from 124`) was up 2 s after the click. `/Applications` holds only
  Amaranth.app (staging and the old bundle deleted).
- After: `--build-info` build 125, commit 83ddbda, not dirty; signature valid (deep, strict); no quarantine attribute;
  designated requirement identical before and after (identifier com.alexmartin.amaranth + the same Apple Development
  leaf certificate), so the microphone/system-audio grants carry over; library 10 meetings, 0 folders, schema 6
  (unchanged). Toolbar: **Updated to build 125**; clicking it removed it.
- Amaranth ▸ Check for Updates… on 125: "You're up to date — Amaranth 0.1.0 (125) is the newest build."

## 2. GitHub, Debug with the opt-in (125 → Debug 126), and an older Release

- Debug 126 (e815250) published as prerelease `build-126-debug` (`scripts/publish.sh --debug`; GitHub shows it as a
  pre-release with the zip and manifest.json).
- On Release 125 with Include Debug builds off: Check for Updates… → "You're up to date — Amaranth 0.1.0 (125) is the
  newest build." With it on (`defaults write com.alexmartin.amaranth updates.includeDebug -bool true`, read live):
  "A new build is available", Available 0.1.0 (126) Debug e815250, 25.1 MB.
- Install and Relaunch: `22:13:51 update 125 → 126: waiting … installed; relaunching`, new process 2 s after the click;
  `--build-info` build 126, channel debug; same leaf certificate; library 10 meetings, schema 6; toolbar "Updated to
  build 126".
- Older build: on Debug 126 with the opt-in off, GitHub's newest Release is 125, and Check for Updates… says "You're up
  to date — Amaranth 0.1.0 (126) Debug is the newest build." (no rollback offered).
- The Software Update window's buttons report an empty AXDescription to System Events even with
  `.accessibilityLabel` (c126); they're clickable by position. VoiceOver reading is left to checklist 88.
