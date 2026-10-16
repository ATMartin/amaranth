# Milestone C: brief for the independent validator

You are validating **Milestone C ("Complete usable workflow")** of Amaranth, a local macOS meeting recorder and
transcriber. The repo is `/Users/alex/sandbox/amaranth-v2`. The plan is `docs/development-plan.txt`, and the backlog is
`docs/implementation-tasks.json` (tasks **T09, T10, T11**). Milestones A and B passed; their verdicts are in
`docs/qualification/milestone-{a,b}-verdict-*.md`.

Milestone C exit (plan §12): *"T09 evidence-backed notes, T10 native review UI, T11 export/search/deletion. A fresh
machine can install models, record a real meeting, correct speakers, inspect note evidence, and export locally."*

## Ground rules
- Be adversarial and independent. Check claims against code, tests, raw evidence, or by running things. Report anything
  overstated, unsupported or contradicted.
- Hardware: one M2 Max (96 GB) on macOS 26.5.2. Base-M2/16 GB and 8 GB gates must be marked **unverified**.
- No person has used the UI interactively, and no real-call corpus or human notes evaluation exists yet. The docs
  must say this. Judge whether what *can* be verified without a person is verified, and whether the pending human
  checks are clearly scoped (`docs/qualification/ui-manual-checklist.md`, the notes review sheets).
- **Don't** run the audio-capture self-tests (`capture-signals`, `capture-routes`, `capture-soak`, `capture-tone`),
  because they raise permission prompts. **Don't** modify source or docs, and don't touch
  `~/Library/Application Support/Amaranth/`. Write scratch files only under `/tmp`. Don't run `xcodegen` or
  `xcodebuild`, which would rewrite `build/` and `Amaranth.xcodeproj`. The Debug app is already built at
  `build/DerivedData/Build/Products/Debug/Amaranth.app`.
- You may run:
  - `swift test --scratch-path /tmp/amaranth-validate-c`, optionally with `--filter`;
  - self-tests on the built app, which need no permissions:
    `…/Amaranth.app/Contents/MacOS/Amaranth --self-test ui-render --self-test-output /tmp/<dir>` (writes PNGs you can
    view), plus `pipeline-e2e --repo $PWD`, `worker-crash` and `worker-hang`;
  - `swift build -c release --product amaranth-bench` then
    `.build/release/amaranth-bench notes-eval ModelStore Benchmarks/Fixtures/public /tmp/<dir>`. This takes about
    15 minutes, uses the real Qwen3-4B model, and copies nothing large.

## Documents to check
- `docs/decisions/notes/0001-evidence-backed-notes.md` (T09)
- `docs/decisions/ui/0001-recording-and-review-ui.md` (T10)
- `docs/decisions/data/0001-search-export-deletion.md` (T11)
- `docs/qualification/tracked-items.md`
- `docs/qualification/ui-manual-checklist.md`
- Evidence:
  - `Benchmarks/Results/2026-10-16-t09-notes/` (`run.log`, the earlier `run1-*`/`run2-*` logs, `notes-review-*.md`);
  - `docs/qualification/evidence/2026-10-16/`.

## What to check (per acceptance in implementation-tasks.json)
- **T09:**
  - two-hour coverage (beginning, middle and end represented);
  - every item has valid evidence;
  - transcript-injected instructions cannot invoke tools or change export/privacy behaviour;
  - failure leaves the transcript and prior summary intact;
  - regeneration never silently overwrites user edits;
  - scratchpad inclusion is explicit;
  - staleness;
  - one bounded repair;
  - contradictions and revisions preserved;
  - the honesty of what the automatic proxies show versus the human gates.
- **T10:**
  - start, stop and save without the terminal;
  - responsiveness with a two-hour transcript;
  - meters not published per callback;
  - actionable states;
  - fixture versus integration agreement on unknown speakers, unavailable playback, stale notes and destructive
    actions;
  - safe close and quit;
  - no silent recording.
- **T11:**
  - exports match the selected revisions, with no scratchpad by default;
  - audio-only deletion keeps text and disables playback and retranscription;
  - deletion during processing cannot be undone by late results;
  - search and caches hold no deleted meeting after relaunch (including the raw-bytes check);
  - exports are described accurately.

## Output
Write `/tmp/milestone-c-verdict.md` and return it in full as your final message:
- an overall **PASS / PASS WITH CONDITIONS / FAIL**;
- per task: met criteria with the evidence you checked, unmet or overstated items, and what you could not verify;
- a prioritized list of required fixes before Milestone D, and a list of acceptable deferrals.
