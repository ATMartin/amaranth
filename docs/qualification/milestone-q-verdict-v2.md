# Milestone Q validator verdict v2: PASS (with one should-fix left open)

Re-checked the working-tree diff (App, scripts, docs/release) against verdict-v1.

## Must-fix items: both resolved
1. Cancel during verify: `Task.checkCancellation()` now follows the sha256, the ditto unzip and the signature facts, and
   precedes `startHelper`. The CancellationError path cleans staging and returns to idle. OK.
2. Spinner forever: a user-initiated check during an in-flight launch check sets `.checking` and `reportFailure`, so the
   in-flight check reports `.failed` (or the result). A later launch check starts with `reportFailure = false`. OK.

## Other fixes reviewed
- check() ignored during an install (allowed again when installPhase is .failed): fine.
- Veto after terminate: the dialog shows a failure after 5 s. The main thread is blocked by the modal alert, so the timer
  resumes after it is dismissed. A slow but legitimate quit may flash the message just before exit; harmless.
- Download cancel race and `defer { downloadTask = nil }`: correct. Update Available outranks Updated: correct.
- Helper `open -R` on restore failure; publish.sh origin check (no grep -q under pipefail); UPDATES.md: fine, `bash -n` clean.

## Should-fix (still open, narrow)
- App/Updates/UpdateInstaller.swift:41-50. After a vetoed quit the helper stays alive for 60 s but the app forgets it
  (no Process reference). If the user retries Install within that window, `prepare` calls `cleanUpStaging()`, deleting the
  first helper's staging. When the app then quits, helper 1 finds the build missing and runs `rm -rf "$STAGING"`, which is
  the same folder helper 2 is swapping from, so the second install can fail ("new build missing", --update-failed relaunch).
  Nothing is lost and the old app stays, but the install fails. Fix: keep the helper Process and `terminate()` it in the 5 s
  failure branch (and before any new install).

## Verified myself
- scripts/test-update-helper.sh passes (4 scenarios). scripts/test-update-verify.sh passes against <scratch>/updates/debug/121
  (checksum, truncation, build mismatch, other team, good).
- Rebuilt Debug app self-tests: update-check (folder) passes, update-verify with --include-debug passes, offline sandbox-exec
  update-check --expect-error passes.
- Not re-run: the interactive Cancel and veto flows (code-read only; they need the real UI), real GitHub calls.
