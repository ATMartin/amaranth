# Milestone S (T97–T100) independent validation — verdict v2

**Verdict: PASS.** (Sonnet validator, 2026-11-03; condensed from its report.) All v1 must-fix and should-fix
findings are fixed. The validator reproduced each fix with its own probes and found no new must-fix or should-fix.

## v1 findings re-checked
- **M1 (search paging):** fixed. 15 meetings × 40 matching lines (about 600 rows), paged with limit 7 until the end
  for 3 queries: 0 duplicates, consecutive ranks, and the first page equals the unpaged result.
- **M2 (64 KiB ceiling):** fixed.
  - Hostile library: 140 KB note line, 100,000-character title, 3,000 people, 50,000-character folder name, 60 meetings
    with long titles and people.
  - Search: 4,696 bytes. List: at most 65,013 bytes over all pages. Metadata: 3,042 bytes, shortened.
  - get transcript/notes: at most 64,841 bytes per page, with exact character totals.
  - A shortened search line's citation still resolves, because the hash uses the full text.
- **S1 (unfinished export from another library):** fixed. Refused; library A can still finish its own export; a
  garbled marker is refused.
- **S2 (notes-app syntax):** fixed.
  - URLs, `www.`, e-mail and `mailto:` are broken by a zero-width space; `%% == $$ ^` are escaped; front matter keeps
    the exact text.
  - Linkify reader: 0 failures on the hostile seed, and a hand-planted bare URL is caught.
- **S3 (capture harness):** fixed. The harness checks every sample and the frame totals. The committed runs show 0
  discontinuities, overruns and lost frames, and frames within 0.1 s of elapsed time.
- **S4 (cursor scope):** fixed. List and search cursors made under `.all` are refused under `.meetings`.
- **N1–N3, N5–N7:** fixed. N3 was checked by keeping a user-edited README. N5 by re-running the 38-URL matrix, where
  a transcript link without `word` is now invalid. N7: odd IDs give an empty URL. N1, N2 and N6 were checked in the
  diff.
- **N4:** accepted as a known limit.

## Regression check
- Milestone S test filter plus ValidatorFixTests: 41 tests in 9 suites passed, plus the contract suite.
- eval: lexical 100%, paraphrase 25%, citations 1314/1314, adversarial 12/12.
- 60×1,000 scale sample: get about 78–107 ms, list 1–4 ms.
- Re-export, kept user edits, and foreign / link / read-only refusals all still hold.

## Remaining (nice-to-have)
- **N-a.** A foreign library was accepted if the unfinished-run marker had been deleted by hand but the journal was
  left. Fix: refuse a journal without a marker or manifest. Applied after v2, with a test.
- **N-b.** The harness tolerance is 0.25 s, but the docs said about 0.1 s. Fix: state both. Applied after v2.
- **N-c.** Title/person rows can fill the 1,000-row candidate pool; for example, one meeting with 3,000 matching
  people left 3 passages. Recorded as a limit.

## Needs a person
- The Obsidian vault window after the disclosed side effect.
- A real-device recording while an export runs.
- The installed Release build: `amaranth://` registration, the File menu item and ⇧⌘E, Export Folder…, and the
  meeting menu item.
- In the export sheet: Stop, VoiceOver and keyboard.
- A real-library export in Obsidian (bare URLs and `%%` shown literally).
- A link clicked from another app, with Amaranth closed and with it open.
