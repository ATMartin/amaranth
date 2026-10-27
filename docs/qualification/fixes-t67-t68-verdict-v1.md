# Fixes group (T67, T68): independent validation, verdict v1

Validator: Sonnet subagent, 2026-10-27, over f24a491 (T67) and 1750aaa (T68). It read the code and docs and ran the
QuietMonitor/CaptureTrim tests; it did not launch the app.

**Verdict: PASS WITH FIXES. No must-fix items.**

Should-fix items, and what was done:

1. *An irreversible trim rests on live words alone; lagging live text could cut speech.* Fixed: words decide only
   while live text is within 15 s of the recording on every source (`LiveTranscriptState.isCaughtUp`); otherwise
   levels decide, as when live text is off. Missed words (ASR dropping speech) remain a known risk the user accepted
   by choosing no Restore.
2. *Double stop: a late notification click or the disk guard during Stop could run `finish()` twice.* Fixed: `stop()`
   returns while already stopping.
3. *Capture state and events after the trim.* Fixed: events open across the cut are clipped to the new end, and
   "captured with gaps" becomes "captured" when the only gaps were in the deleted tail (tests added).
4. *Smaller items.* Fixed: no Return default on Stop & Make Notes; the strip's Stop tooltip says it trims while the
   alert is up; Settings says changes apply from the next recording; `stop-layout.sh` copes with a missing
   preferences domain.

T67: root cause and fix accepted as at the cause. The validator noted the probe fakes recorder state via the render
hook (the banner, toolbar and split view are real) and that it couldn't re-run the before/after claim (the run that
showed all 8 variants failing before the fix is in the bug file).
