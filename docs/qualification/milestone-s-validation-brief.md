# Milestone S (T97–T100, shared read model and portable export): brief for the independent validator

You are validating **Milestone S** of Amaranth, a local macOS meeting recorder: a versioned external read model of a
meeting (snapshots + `amaranth://` source links), bounded list/search/fetch over it, and bulk Markdown + JSON snapshot
export, with qualification evidence. MCP (Milestone T) and the vault mirror (Milestone U) are **not** in scope.

- **Repo:** `/Users/alex/sandbox/amaranth-v2`.
- **Spec:** `docs/decisions/0009-external-meeting-access-spec.md`; implemented parts are §1a, §2a, §4a.
- **Backlog:** `docs/implementation-tasks.json`, milestone "S" and tasks T97–T100 (deliverables, acceptance, fallback).
- **Commits:** `git log e6c9f46~1..HEAD` — e6c9f46 (spec accepted, placement), T97 39c541d, T98 e9c72f3, T99 f9cc506,
  then T100.
- **Evidence:** `docs/qualification/milestone-s/` (`t98-retrieval-report.md`, `t100-qualification.md`, screenshots),
  `Benchmarks/Results/access-t98/`, `Benchmarks/Results/access-t100/`. User doc: `docs/release/EXPORTS.md`.

## User decisions (2026-11-03)
- Pick up S now (before T21); accept the tightened T97/T99 wording (no original generated-summary body or attendee
  emails in the external schema; evidence can't expose hidden text; notes stay as shown after trims, disclosed).
- T98 scale measured on **200 meetings × 1,000 lines**; the 1,000-meeting gate is reported as *not measured (user
  decision)* — don't fail the milestone for that alone, but do check the 200-meeting claim.
- T100 reader check = a generic parser script plus a throwaway Obsidian vault (never the user's vaults).
- Commit per task. After validation: back up the real library and install the Release build locally; no publishing.

## Ground rules
- Be adversarial and independent: check claims against code, tests and evidence; try to break it.
- `<scratch>` = `/private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/a4bccc85-eef6-49d4-8bfc-5eb3cb6efb8a/scratchpad`.
  Work only under `<scratch>/validator/`. `rm` is aliased: use `/bin/rm -f`.
- **Don't** modify source or docs. **Don't** touch `~/Library/Application Support/Amaranth`, `/Applications/Amaranth.app`,
  the app's defaults (`com.alexmartin.amaranth`), Obsidian or its settings, git history, or push. Don't launch the GUI
  app (the Debug build shares preferences with the user's running app); the screenshots are the UI evidence. Don't run
  `xcodegen`, `xcodebuild`, `scripts/check.sh` or install scripts (I run `check.sh`; its log is
  `<scratch>/check-s.log`).
- You may run:
  - `swift test --scratch-path <scratch>/validator/build --filter "MeetingSnapshotTests|CitationURLTests|ExternalSnapshotContract|RetrievalTests|BulkExport|AccessDeletion|DataLifecycle"`
    (add your own temporary tests only under `<scratch>/validator/`; don't add files to the repo).
  - `swift build -c release --product amaranth-access --scratch-path <scratch>/validator/build`, then the CLI on
    **copies** of libraries in `<scratch>/validator/`: `seed-demo`, `seed-eval`, `seed-hostile`, `seed-scale` (keep it
    ≤ 200×1000), `snapshot`, `resolve`, `export`, `eval`, `scale`, `record-under-load` (≤ 60 s). Existing synthetic
    libraries you may copy: `<scratch>/eval-lib`, `<scratch>/scale-lib` (416 MB), `<scratch>/hostile-lib`.
  - `<scratch>/venv/bin/python Benchmarks/AccessEval/read-export.py <destination>` and your own parsers in that venv.
  - `hdiutil` small disk images under `<scratch>/validator/` (detach them when done).

## What to judge
1. **T97 contract:** the snapshot equals what the app shows (corrections, deleted lines, both trims, renames, overlap,
   gaps, notes document as shown, authorship, uncertainty, staleness); notes-only/processing/failed/audio-deleted
   states are explicit; nothing hidden can come out (raw revisions, summary body, emails, audio, work files, paths),
   including through evidence; fingerprint changes on every relevant mutation and is stable otherwise; snapshots are
   consistent under concurrent edits; deleted meetings can't be fetched; golden fixture + version rule; the library ID
   file. Source links: strict parsing (try your own hostile URLs), resolution never points at a different line, never
   reveals old text, URL handling only navigates (read `App/Library/LibraryModel.swift` `openSourceLink`/`follow`).
2. **T98 retrieval:** filters and scope applied before ranking and context windows (`Storage/Search/Retriever.swift`
   `meetings:`), guessed IDs, stale/foreign cursors, tie stability, the content-generation counter covering every
   content/scope write (look for writes that don't bump it), 64 KiB budget and fragments (try to make a response exceed
   it), input ceilings, malicious FTS input, cancellation/deadline. Recall and citation numbers: re-run `eval`; judge
   whether the question set is fair (not tuned to pass) and whether the u06 re-specification is legitimate. Scale:
   re-run a smaller `scale` sample and compare.
3. **T99 export:** parity with snapshots; Markdown/YAML inertness (try your own hostile metadata via a scratch test or
   `seed-hostile`-like data); UUID paths across renames/duplicate titles; manifest committed last; journal/marker;
   cancel/crash/disk-full/permission behaviour and safe retry; user-modified files never clobbered; foreign/unknown/
   linked destinations refused; unchanged meetings not rewritten; single-meeting exports unchanged (`Export/Exporter.swift`
   diff is a pure extraction); the sheet's states and wording (`App/Library/BulkExportSheet.swift`, screenshots).
4. **T100 qualification:** each spec 0009 Milestone S gate has real evidence; failures/limits are stated, not
   relabelled; `docs/release/EXPORTS.md` and README's privacy line are accurate; the record-under-load harness actually
   measures what it claims (read `Benchmarks/Access/RecordUnderLoad.swift`).

## Output
Write `docs/qualification/milestone-s-verdict-v1.md` content as your final message (I will save it): verdict PASS / PASS
WITH FIXES / FAIL; findings grouped must-fix / should-fix / nice-to-have, each with file:line, how you verified it, and
a concrete fix; then "Needs a person" (hands-on items you couldn't automate) and what you ran.
