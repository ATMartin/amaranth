# Milestone N: brief for the independent validator

You are validating **Milestone N ("Ask anything over meetings", T52–T55)** of Amaranth, a local macOS meeting recorder
and transcriber.

- **Repo:** `/Users/alex/sandbox/amaranth-v2`.
- **Backlog:** `docs/implementation-tasks.json` (ids T52–T55), with each task's deliverables, acceptance and fallback.
- **Source:** `docs/decisions/0005-design-review-2026-10-23.md` and `docs/design-review/2026-10-23/transcript.md` (08:40–09:09);
  reference image `docs/design-review/2026-10-23/granola-home-sidebar.png`.
- **Commits (one per task):** `git log --oneline 89a95c5..HEAD` (T52 2e1bc29, T53 02dcfb5, T54 9526555, T55 a6844e0).
- **Decision records:** `docs/decisions/data/0002-retrieval.md` (T53) and `docs/decisions/notes/0003-ask-anything-answers.md` (T54, T55).
- **Evidence:**
  - `docs/qualification/evidence/2026-10-27/ask-anything/`;
  - eval results `Benchmarks/Results/2026-10-27-ask-t54b/` and `Benchmarks/Results/2026-10-27-ask-t55/`;
  - question set `Benchmarks/Ask/questions.json`;
  - hands-on checklist `docs/qualification/ui-manual-checklist.md` (new items 46–51).

## User decisions (2026-10-27)
- All of N including the optional T55. One commit per task, hands-off; stop after N.
- The question set **may quote the user's work meetings** (Leesa 1:1, Andrew 1:1, Staffing with transcription, Moxee).
  The user accepted their text being committed. "Staffing call" has no consent and must never be used: check that.
- Real-library validation is allowed as in Milestones K/M. Opening the Debug app migrates the real library to
  **schema v4** (expected; the installed Release app will refuse it until the user installs the new build).
- Milestone order is now K → M → N → O → J → L → T21 → F.

## Ground rules
- Be adversarial and independent. Check claims against code, tests and evidence, or by running things.
- **Don't** modify source or docs. Put scratch files only under `/private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/d08db394-e603-4cfc-89f1-86005c4c65c5/scratchpad/validator/`.
- **Don't** run `xcodegen` or `xcodebuild`: the Debug build in `build/DerivedData` is the final T55 code.
  Don't run the perf-suite or any `capture-*` self-test.
- `rm` is aliased; use `/bin/rm -f`.
- You may run:
  - `swift test --scratch-path /private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/d08db394-e603-4cfc-89f1-86005c4c65c5/scratchpad/validator/build --filter "AskAnything|AskFollowUp|Retriever|Answer|MeetingStoreTests|DataLifecycle"`
    (the corpus tests need `Tests/Data/Recordings`, which exists locally).
  - The eval, offline, about 4 minutes. Build it first with
    `swift build -c release --product amaranth-bench --scratch-path /private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/d08db394-e603-4cfc-89f1-86005c4c65c5/scratchpad/validator/bench`, then:
    `sandbox-exec -p '(version 1)(allow default)(deny network*)' /private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/d08db394-e603-4cfc-89f1-86005c4c65c5/scratchpad/validator/bench/release/amaranth-bench ask-eval ModelStore/qwen3-4b-instruct-2507-q4_k_m/Qwen_Qwen3-4B-Instruct-2507-Q4_K_M.gguf Benchmarks/Ask/questions.json /private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/d08db394-e603-4cfc-89f1-86005c4c65c5/scratchpad/validator/eval`
    (`--range q01-q20` or `--only q03,q21` for subsets; `ASK_EVAL_DEBUG=1` prints the passages and raw model output).
    Compare with the committed reports.
  - The self-tests, executing the binary directly with a 300 s timeout:
    - `build/DerivedData/Build/Products/Debug/Amaranth.app/Contents/MacOS/Amaranth --self-test ui-render --self-test-output /private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/d08db394-e603-4cfc-89f1-86005c4c65c5/scratchpad/validator/png`
      must pass. Look at `ask-*.png` in `png/light/` and `png/dark/`.
    - `open -W -n build/DerivedData/Build/Products/Debug/Amaranth.app --stdout /private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/d08db394-e603-4cfc-89f1-86005c4c65c5/scratchpad/validator/askw.log --args --self-test ask-worker`
      exercises the real XPC worker on a temporary library and must pass.
- You may read the real database **read-only** with `sqlite3 -readonly` (schema, `PRAGMA user_version`, row counts by
  `kind` in `search_index`). Don't print transcript or notes text.

## Hands-on (real app, real library)
Launch with `open -n build/DerivedData/Build/Products/Debug/Amaranth.app`. Drive it with `osascript` / System Events
(Terminal has Accessibility) and capture with `screencapture -x`.

Quit it at the end with Amaranth ▸ Quit, or kill it by PID from
`pgrep -f "Debug/Amaranth.app/Contents/MacOS/Amaranth$"`. Never kill it by name.

**Allowed (look-only plus asking):**
- select meetings and switch tabs;
- use the ask field: click, ⌘K, typing, Return, ↑/↓, Esc, the scope switch, clicking matches and citation chips;
- ask as many questions as you like, including follow-ups, injection-style questions and questions across meetings;
- toggle appearance (put it back to Match system when done).

Check checklist items 46–48, 50 and 51 in Light and Dark, **using only the keyboard** for item 46.

**Never:**
- press Record (or ⌘⇧R);
- rename anything, edit people, merge or assign speakers, or Correct Text;
- edit Your notes or the scratchpad;
- regenerate notes, Retry or Process;
- delete anything, export, or install or remove models.

**Privacy:** never quote transcript, notes or answer text from the real library in your report; meeting titles are fine.
Real-content screenshots stay in `/private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/d08db394-e603-4cfc-89f1-86005c4c65c5/scratchpad/validator/`.

Item 49 needs recording, and the Wi-Fi part needs a person: list them under "Needs a person", with VoiceOver.

## What to judge
1. **T52.**
   - The field is pinned to the bottom of the detail pane and works with the keyboard only (⌘K = All meetings, Return,
     ↑/↓, Return opens, Esc).
   - The old sidebar search field is gone.
   - Hits are grouped by meeting, with snippet highlighting and jump-to-row, also across meetings.
   - The scope switch works; `LibraryModel.query/hits/open` is still the engine.
   - ui-render passes. Is the fallback (toolbar) unnecessary, i.e. does the bar ever cover the live transcript?
2. **T53.**
   - Speaker and person kinds are indexed; re-index on rename and on `setPeople`.
   - The one-time v4 migration is correct and idempotent (and the real library migrated cleanly).
   - Retriever: bm25, expansion, ±2 windows, de-duplication, top 12, evidence refs.
   - The < 50 ms claim, measured on the longest corpus meeting.
   - Does the T54 fix (windows capped at 6 rows, no shared lines) still meet "±2 windowing, de-duplication"?
3. **T54.**
   - The `.answer` worker request: JSON shape, refusal, and citations validated against real passages.
   - Streaming, the "may be wrong" caption, and chips that jump to the cited row.
   - Offline run works; citation validity is 100%; latency is reported (first ≤ 3 s, full ≤ 10 s).
   - Injection questions don't leak the prompt; the suite follows the notes pattern.
   - Yielding: answers never load the model while recording or while transcript work is active (read
     `AnswerModel.busyReason` wiring and `ModelProvider.answers`/`notes`). Could an answer evict ASR models a
     running job is using?
   - Memory of the second llama context.
   - Can an answer be cancelled?
4. **T55.**
   - The last 3 turns are kept as context; follow-up retrieval works.
   - Cross-meeting citations are labelled with meeting title and time and open the right meeting and row.
   - 10 cross-meeting questions plus follow-ups, with expected evidence (spot-check that the evidence lines really
     support the expected answers).
   - Follow-ups resolve pronouns.
5. **Integrity of the eval.** Is the question set fair (not tuned to the system)? Do the metrics mean what the reports
   say? Are there over-claims in the decision records?
6. **Regressions elsewhere:** sidebar, meeting switching, recording toolbar, notes evidence links, exports unchanged,
   and `Recording` tab untouched.

Write your verdict to `/private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/d08db394-e603-4cfc-89f1-86005c4c65c5/scratchpad/validator/milestone-n-verdict.md`: PASS / PASS WITH FIXES / FAIL, a must-fix list, a should-fix list,
a "Needs a person" list, and what you checked. Return the same summary.
