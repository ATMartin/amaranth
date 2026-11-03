# T100: Milestone S qualification evidence (2026-11-03)

Synthetic, isolated libraries only; no real meeting text anywhere in this evidence. Hardware/OS: Apple M2 Max, 96 GB,
macOS 27.0.1 (26A434), Swift 6.4.2, system SQLite 3.54.0, Xcode toolchain with macOS 27.2 SDK; load average ≈ 2.5 (the
user's Release app was running). Tools: `amaranth-access` (release build), the Debug app with `--library-root`,
PyYAML 6.0.2 + markdown-it-py 3.0.0 (CommonMark) in a throwaway venv, Obsidian (installed version, throwaway vault).

## Gates (spec 0009 §5, Milestone S)

| Gate | Evidence | Result |
|---|---|---|
| Export parity | `BulkExportTests.multiMeetingExportMatchesCurrentContentAndLeaksNothing`: each exported `meeting.json` equals the reader's snapshot (read time aside) for edited/stale/trimmed, notes-only and still-recording meetings; `MeetingSnapshotTests` and the golden fixture pin the snapshot to what the app shows | pass |
| Hidden text never leaks | Planted markers (corrected word, deleted line, both trims, generated summary body, attendee email) absent from snapshots, search, every export file; local paths absent; no audio files | pass |
| Retrieval report | `t98-retrieval-report.md`: lexical Recall@10 100% (33 q.), paraphrase 25% (8 q., misses listed), citations 1257/1257, adversarial 12/12 | pass (lexical); paraphrase gap documented |
| Scale | 200 meetings × 1,000 lines: search warm p95 201 ms / cold p95 100 ms; get ≈ 85 ms; list ≈ 4 ms; peak 59 MiB; no models | pass at 200 meetings; **1,000 meetings not measured (user decision)** |
| Edits and deletion | fingerprints change for every mutation; concurrent edits give consistent snapshots; deletion races never half-show or resurrect a meeting; late transcript/notes publication after deletion is refused; meeting deleted mid-export is reported, not written; audio-only deletion keeps text and says so (`AccessDeletionTests`, `MeetingSnapshotTests`) | pass |
| Citations | URL parsing rejects 28 malicious/invalid forms before any lookup; unchanged sources resolve; corrected, deleted, reprocessed or edited sources say *changed*; deleted meetings *unavailable* (`CitationURLTests`). In the app: a current link highlights the line, a changed link shows "This source has changed" (`t97-link-*.png`); a link taken from an exported `meeting.md` opens the cited line (`t100-citation.png`) | pass |
| Generic reader | `read-export.py` (CommonMark **with linkify**, as GFM/Obsidian autolink) over a 42-meeting export: 0 failures (front matter keys, IDs/fingerprints agree across md/json/folder, CommonMark parse, no raw HTML, only `amaranth://` links to the same meeting, manifest hashes). Over 12 meetings with hostile titles/people/folder/text (quotes, newlines, `---`, YAML anchors/tags, `<script>`, `javascript:` links, `../` paths, U+2028/2029/0085/FEFF, RTL override, Markdown syntax, bare URLs/`www.`/e-mail, Obsidian `%%`/`==`/`$$`/`^`): 0 failures; a bare URL planted by hand into one file is caught; titles/people/folder round-trip byte-exact through PyYAML. Obsidian opens the folder as a plain vault, front matter as typed properties, no plugin (`t100-obsidian.png`) | pass |
| Export failure handling | Real full disk (2 MB HFS+ image): 20 meetings written, 23 per-meeting errors naming the file ("…/meeting.json couldn't be written: The volume … is out of space"), no manifest, folder marked incomplete. Copied to a disk with space and exported again: complete, nothing wrongly kept, generic reader 0 failures. Cancel/retry, permission failure, file-in-the-way, user-edited files kept, foreign/unknown/linked folders refused (`BulkExportTests`) | pass |
| Recording health under load | `amaranth-access record-under-load`: two synthetic sources in real time through the real ring, segment writer, journal and store indexer, sharing the store with 2 reader threads (list/search/get) and continuous bulk exports of 200 meetings. Every frame of every segment is checked (each sample = previous + 1), and total frames are compared with the time recorded. Baseline 30 s, and 60 s under load (558 reader operations, one full 200-meeting export): mic and system 0 discontinuities; frames within 0.1 s of elapsed time (the harness fails beyond 0.25 s; +3,888 frames, the frames between the stop request and the stop); 0 ring overrun frames; 0 writer lost frames or gap events; 0 missing-audio events; 62/62 segments indexed. Stop took 0.48 s under load vs 0.18 s idle (`Benchmarks/Results/access-t100/rul-*.json`). The first version checked only segment boundaries (validator S3) | pass (synthetic sources) |
| UI | Export Meetings sheet in light and dark, keyboard-only run (Return → open panel → export) on the Debug build with a synthetic library; result summary (`t99-*.png`) | pass, partly; see below |

## Validator round 1 (verdict v1: PASS WITH FIXES)

All must-fix and should-fix findings were fixed with regression tests (`Tests/DataLifecycle/ValidatorFixTests.swift`),
and so were N1–N3 and N5–N7. N4 (one bound parameter per in-scope meeting) is recorded as a known limit for very large
libraries. See `docs/qualification/milestone-s-changes-after-verdict-v1.md`.

## Not verified / limits

- **1,000-meeting scale** (≈ 1 M lines): not measured, user decision. Extrapolation only: search could approach 0.5 s.
- **Real audio devices under load:** capture health used `SyntheticSource`; real Core Audio / process-tap callbacks
  while exporting are unverified (hands-on item for the user: record a short call while an export of the library runs).
- **Packaged Release build:** export and links were exercised through the Debug app (`--library-root` exists only in
  Debug) and the release-built `amaranth-access`, which runs the same `MeetingAccess` code. The installed Release app's
  menus and URL registration are checked after installation, on the real library, by the user.
- **UI by hand:** the progress state (too quick to capture), Stop during a long export, VoiceOver labels, the folder
  right-click item (scripting couldn't reach the sidebar rows; reached the same sheet via View ▸ Show Folder and File
  ▸ Export Meetings…), and the meeting ⋯ ▸ Export ▸ To a Folder… item are left for the user's hands-on pass.
- **Candidate pool:** search reads 1,000 FTS rows before ranking; a meeting whose title or 3,000 listed people all match can use most of them, leaving fewer passages from other meetings (validator v2 N-c; same weakness as before, now with a larger pool).
- **Large scopes:** search binds one SQL parameter per in-scope meeting (validator N4); fine for thousands of meetings, but far beyond that it would need a temporary table.
- **Paraphrase questions** (25% Recall@10): lexical search doesn't match meaning; hybrid search isn't proposed yet.
- **Speaker names before reconciliation:** exports and search apply a speaker rename immediately; the app's transcript
  view shows it once reconciliation has run (normally seconds). Same rule search already used.
- **Obsidian side effect during this check:** Obsidian deleted the window-geometry file of the user's own vault
  (`~/Library/Application Support/obsidian/<vault-id>.json`, window position/size only) because that vault was marked
  not-open for the throwaway launch. `obsidian.json` was restored exactly; the user's vault window opens at the default
  size once.
- Notes stay as shown after transcript lines are deleted or trimmed (by design, T96); exports say so per meeting.

## Commands

    swift build -c release --product amaranth-access --scratch-path .build-check; BIN=.build-check/out/Products/Release/amaranth-access
    $BIN seed-scale <s>/scale-lib 200 1000
    $BIN record-under-load <s>/scale-lib 30 <s>/rul-dest --no-load;  $BIN record-under-load <s>/scale-lib 60 <s>/rul-dest
    $BIN seed-hostile <s>/hostile-lib && $BIN export <s>/hostile-lib <s>/hostile-dest
    hdiutil create -size 2m -fs HFS+ -volname amrfull full.dmg; hdiutil attach -nobrowse -mountpoint <s>/full full.dmg
    $BIN export <s>/eval-lib <s>/full    # disk full
    python3 -m venv venv && venv/bin/pip install pyyaml==6.0.2 markdown-it-py==3.0.0
    venv/bin/python Benchmarks/AccessEval/read-export.py <destination>
    open -n -a build/DerivedData/Build/Products/Debug/Amaranth.app '<amaranth:// link>' --args --library-root <s>/t99-lib
    swift test --filter "MeetingSnapshotTests|CitationURLTests|ExternalSnapshotContract|RetrievalTests|BulkExport|AccessDeletion"
    scripts/check.sh
