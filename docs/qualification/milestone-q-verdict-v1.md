# Milestone Q validator verdict v1: PASS WITH FIXES

## Must-fix
1. App/Updates/UpdateInstaller.swift:27-51 and :62-94. Cancel during "Checking the download…" is ignored and the install proceeds.
   `Task.checkCancellation()` runs only once (line 69, right after the download). The verify phase (sha256, ditto, signature
   facts) awaits detached work and `Self.run`, none of which observe cancellation. `install()` never re-checks before
   `startHelper` + `NSApp.terminate`. Scenario: user clicks Cancel while the dialog says "Checking the download…". The task is
   cancelled but prepare() returns normally, so the app quits and is replaced anyway. Fix: `try Task.checkCancellation()` after
   prepare() (and before startHelper), and between the steps of prepare.
2. App/Updates/UpdateModel.swift:97-111 with UpdateViews.swift:16-18 and :74-77. The window can spin on "Checking for updates…"
   forever. A launch check (userInitiated: false) is in flight, up to 15 s, e.g. offline at launch. The user chooses Amaranth >
   Check for Updates…. `check(userInitiated: true)` hits `guard checkTask == nil` and returns. When the launch check fails it
   sets phase to .idle (quiet failure). The window shows `.idle` as the "Checking…" spinner with only Close, and onAppear won't
   re-check. The user never sees the offline message. Fix: upgrade the in-flight check to user-initiated, or have the failure
   path set .failed when a window request arrived, or re-run the check.

## Should-fix
- UpdateInstaller.swift:41 with AmaranthApp.swift:243-252 and update-helper.sh:21-29. If `NSApp.terminate` is vetoed
  (recording started in the gap, or a "Keep Recording" answer), installPhase stays `.relaunching` ("Relaunching…", no buttons)
  and the helper gives up after 60 s and deletes staging. Nothing is lost, but the dialog is stuck until it is reopened after a
  restart. Reset to idle if the app is still running some seconds after terminate, and kill the helper.
- UpdateViews.swift:16-18. Check for Updates… during an install resets `phase` to .checking/.failed. The install progress and
  Cancel button disappear while the download continues and the app quits unexpectedly. Ignore check requests while installPhase != .idle.
- UpdateInstaller.swift:104-134. Cancel racing the start of the download: `onCancel` runs before `downloadTask` is set, so the
  cancel is lost until the post-download checkCancellation. `downloadTask` isn't nil'd on the error path (line 134 skipped).
- update-helper.sh:47. If the restore fails (exit 2) nothing is relaunched or surfaced; the user has no app at /Applications
  (it is left in /Applications/.Amaranth-update/previous.app, hidden). Very unlikely, but consider leaving a visible
  note or opening the log.
- publish.sh:37. `git branch -r --contains | grep -q` under pipefail is a theoretical SIGPIPE false "not on origin" (output is
  tiny, so low risk); use `grep >/dev/null`.
- UpdateModel.swift:83-88. The "Updated to build N" note takes precedence over "Update Available" until dismissed, so a
  newer build found at that launch stays hidden. Minor.
- The build number is the commit count, so a history rewrite or shallow clone gives wrong or lower numbers. Documented
  behaviour of the design; just note it in UPDATES.md.

## Checked and found sound
- stamp-build.sh runs for app and worker after Info.plist processing and before signing (postBuildScripts, basedOnDependencyAnalysis
  false, user-script sandboxing off). build-app.sh refuses a stale stamp and a worker mismatch. `--build-info` is present.
- publish.sh refuses a dirty tree, an unpushed HEAD (GitHub) and an existing tag/dir. It uploads the zip first and manifest.json last,
  and the manifest size/sha256 come from the zip it just made. `--local-only` stages in a dot folder and renames it, and the
  local source skips dot folders. Bash 3.2 empty arrays are handled with `${ARGS[@]+...}`.
- install-local.sh and build-release.sh keep their DMG, team check and recording refusal.
- Catalog: team and bundle match, build > running, release beats debug on a tie, macOS minimum, well-formed rules. GitHub source: one list
  request, no cache, at most 5 manifests, drafts/uploading/mismatches skipped, rate limit and offline mapped, no retry loop.
- Installer: refusal while recording or outside /Applications, same-volume staging, size then sha256 before unzip, deep strict nested
  signature, bundle ID, team, arm64, minimum macOS, build and channel before anything moves, and quarantine cleared only afterwards.
  The helper waits for the exact PID, restores on a failed swap, deletes the old app, and strips its test hooks (79e74fb fix is correct).
  A second install is refused while one is in progress (installTask guard).

## Verified myself vs taken from evidence
- Verified: code read of all listed files; `scripts/test-update-helper.sh` passes (good swap, failed swap, missing build, non-quitting
  app); `swift test --filter "Update|BuildInfo|Install|Recorded"` passes (22 update tests in 6 suites, plus the ASR e2e);
  Debug app `update-check` self-test against the local folder passes.
- From evidence (docs/qualification/milestone-q-e2e.md and q-e2e/): the real-app 124>125>126>127>128 runs, the failed swap,
  the signing-identity continuity and library counts, the rejections, offline. Not re-run: real GitHub calls, renders.
