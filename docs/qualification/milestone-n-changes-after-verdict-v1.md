# Milestone N: changes after verdict v1

Verdict v1 (`milestone-n-verdict-v1.md`): PASS WITH FIXES.

## Must-fix
1. **Return didn't open the ↑/↓-highlighted hit** (checklist 46).
   - Committing the field set the same text again, and `LibraryModel.query`'s `didSet` cleared the highlight before
     `submitAsk` ran.
   - Now only a real change re-searches and clears the highlight.
   - ui-render now sets the same text before Return and checks that the highlight survives.

## Should-fix
- **"No matches" under an answer.** Keyword search needs every word on one line. When nothing matches all words, the
  panel now lists lines with any of them, ranked by bm25 (`MeetingStore.search(_:in:anyTerm:)`, with a test).
- **The eval's "correct" overstated quality.**
  - The report now names the metric for what it is: an expected line cited, or a refusal when unanswerable.
  - notes/0003 adds a hand grading of all 42 answers: 31 right, 6 partly, 3 wrong, 2 refused. It names q18, q26 and q41.
- **The question set is not held out.** notes/0003 now says so, and that `answer-v2`, the checker and the budget were
  tuned on it.
- **Answers and the speech models.**
  - Pressing Record cancels an answer in progress.
  - The cost an answer leaves for the next transcription (reloading the speech models) is measured at 0.2 s, for
    2 decoders and 2 VADs with a warm Core ML cache. The diarizer, live ASR and a cold cache are not measured.
  - The answer context's memory is measured at 436 MB, after shrinking the context from 6,144 to 3,072 tokens; it was
    about twice that before.
- **Stale docs and tests.**
  - data/0002 describes the final windowing (6-row cap, no shared lines) and the re-measured timings (longest meeting
    max 12.0 ms).
  - New unit test: `RetrieverWindowTests` (`RetrieverSpreadTests` came with T55).
- **First-text margin.** Prompts near the old 2,600-token budget took 2.3–3.5 s when repeated. The budget is now 2,200
  tokens. Final run: first text max 2.23 s; cross-meeting "2+ meetings cited" moved from 8/11 to 7/11.
- **Leftover ui-render plists.** ui-render left ~140 `amaranth-ui-render-*.plist` files in ~/Library/Preferences. It now
  uses two fixed suite names, so at most two empty files exist; the random leftovers were removed.

Also found while re-running the eval: its injection raw-output check built prompts without the budget. It now uses
`Answerer.fittedPrompt`, the same code as answers.

## Needs a person (unchanged)
- Checklist 49: ask while recording, then while transcribing, then with Wi-Fi off.
- VoiceOver over the field, panel and chips.
- Return-to-open with a physical keyboard.
- The work-Mac library's v2 → v4 migration.
- Install the new Release build before opening the library with it.
