# Milestone R (T89–T94): brief for the independent validator

You are validating **Milestone R** of Amaranth, a local macOS meeting recorder: one editable notes field per meeting
(the private scratchpad and "Your notes" are gone; typing during the meeting feeds generation).

- **Repo:** `/Users/alex/sandbox/amaranth-v2`.
- **Spec:** `docs/decisions/0008-single-notes-field-spec.md` (accepted 2026-10-30; read it first).
- **Backlog:** `docs/implementation-tasks.json`, tasks T89–T95 (deliverables, acceptance, and each task's `status` text
  describing what was done and any deviation). Milestone L's T46–T48 were revised by T94.
- **Commits (one per task):** `git log 26325e5..HEAD` (26325e5 is the spec and task list; then T89 6081852, T90 2688f2d,
  T91 d46632c, T92 b935790, T93 d12c2ce, T94 5b02611). Each commit message lists what changed and any deviation.

## User decisions
- 2026-10-30: every recommendation in the spec (user lines always survive, cited or under "Also noted"; Regenerate asks
  and keeps previous versions; snapshot + "Replace?" while generating; inline source chips; rich-text editor; typed-at times).
- 2026-10-31: scratchpads that were **never** used for generation are **deleted** by the v6 migration (the spec's open
  item; spec and tasks updated). The real library is backed up before the installed build migrates it.
- Hands-on checks in the real app are left to the user (checklist items 78–84 in `docs/qualification/ui-manual-checklist.md`).
  The user's installed Release app is running against the real library: don't launch a second instance of any build.

## Known deviations to judge (not to take on trust)
- **Editor (T91):** a SwiftUI line-per-block editor rather than one AttributedString/NSTextView, so block identity, author
  and chips are explicit. Judge whether it meets spec §6 ("one rich-text editor with headings and bullets…").
- **Prompt line format (T90):** a typed line renders as `[90001] (PERSONAL NOTE typed by the user at 12:34, not spoken) …`
  rather than the spec's illustrative `PERSONAL NOTE (typed at 12:34): …`, keeping the existing PERSONAL NOTE label the
  unchanged system prompt describes.
- **Pending results (T90):** "held" is derived (current summary ≠ the document's `basedOnSummaryRevisionID`), so it
  survives relaunch (the task said that wasn't required). A held summary does become the meeting's current summary.
- **Model block evidence (T91):** blocks carry the item's `evidence`, not `ownerEvidence` (as the chips showed before).
- **Legacy decode (T94):** `ScratchpadEvidence`, `.personalNote`, `scratchpadRevisionID`, `influencedByPersonalNotes`
  stay in Domain so stored v5 summaries decode; judge against T94's grep acceptance.

## Ground rules
- Be adversarial and independent; check claims against code, tests and renders.
- `<scratch>` below is `/private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/bce43215-1247-4e3e-beb6-dec263755cbe/scratchpad`.
- **Don't** modify source or docs. Scratch files only under `<scratch>/validator/`.
- **Don't** run `xcodegen`/`xcodebuild` or `scripts/check.sh`; don't `open` the app; never touch
  `~/Library/Application Support/Amaranth` (the real library). `rm` is aliased; use `/bin/rm -f`.
- You may run `swift test --scratch-path <scratch>/validator/build` (all of it, or `--filter`) and the headless render:
  `timeout 400 build/DerivedData/Build/Products/Debug/Amaranth.app/Contents/MacOS/Amaranth --self-test ui-render --self-test-output <scratch>/validator/png`
  (temporary store; must end with `{"result":"pass"}`). Notes scenes: `notes-<meeting>.png`, `notes-details-<meeting>.png`,
  `notes-state-edited.png`, `notes-state-pending-replace.png`, `notes-state-user-lines-only.png`, `live-notes-open.png`,
  `live-notes-closed.png`, in `light/` and `dark/`.
- You may migrate a **copy** of the real library: `cp -R <scratch>/libcopy <scratch>/validator/libcopy` (a consistent
  `sqlite3 .backup` taken read-only), then
  `AMARANTH_LIBRARY_COPY=<scratch>/validator/libcopy swift test --scratch-path <scratch>/validator/build --filter realLibraryCopy`
  (prints counts only). Don't print or quote meeting content in your report.
- Evidence already gathered (read, don't re-run): `<scratch>/check95.log` (scripts/check.sh at HEAD),
  `<scratch>/pipeline-e2e.log` (`--self-test pipeline-e2e`), `<scratch>/png94/` (ui-render at T94), and the real-library
  copy result recorded in T95's status in the backlog.

## What to judge
1. **T89** domain types and authorship rule; v6 schema + data step in the same transaction; migration per spec §8 with
   the 2026-10-31 decision (only the scratchpad revision used for notes survives; never-included text gone from notes,
   search, exports and the database bytes); every live meeting gets exactly one document; deletion purges the new table.
2. **T90** user lines always in the input (only user blocks; cap and its limitation); no user lines → requests
   byte-identical to notes-v3 (judge `NotesPromptGoldenTests`: was the hash really pinned before the change? `git show
   2688f2d~1` has no T90 code); a user line can't make a decision or next step alone; survival rule (property test);
   snapshot publishing, held results, Replace (lines typed after the snapshot kept), Dismiss; staleness no longer
   depends on notes; job keys include the user lines.
3. **T91** editing persists across relaunch; Regenerate asks when there are edits, keeps typed lines, Previous Versions
   restores exactly; banners; chips, uncertain marker, Show in Transcript, Limitations collapsed; debounced saves flushed
   on switch/disappear/quit; the race where the user types while new notes are published (draft not reloaded while
   dirty, save keeps the old `basedOn`, result shows as pending): is anything ever lost or overwritten silently?
4. **T92** live Notes field: typed-at times, edits/insertions/deletions, save cadence and flush at Stop before generation.
5. **T93** exports show the notes as the pane does (TXT/MD/JSON v2, Markdown escaping of typed text); search finds user
   and model lines; Ask cites a user line as "your note" and tells the model it was not spoken.
6. **T94** grep acceptance; docs amendments; T46–T48 revised on the notes document.
7. Regressions: anything else these commits broke (notes generation, evidence jumps, exports of old meetings, Ask,
   deletion bytes, light/dark parity, VoiceOver labels in the notes editor).

## Report
Write your verdict to `<scratch>/validator/verdict.md`: **PASS**, **PASS WITH FIXES** or **FAIL**, then numbered
**must-fix** (acceptance not met or a real bug) and **should-fix** items, each with file:line and evidence, then a
list of hands-on checks you recommend the user do. Keep real meeting content out of the report.
