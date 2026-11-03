# Milestone Q (T70–T73, updates): brief for the independent validator

You are validating **Milestone Q (updates)** of Amaranth, a local macOS meeting recorder: numbered builds published to
GitHub Releases (or a local folder) and installed from inside the app with Check for Updates….

- **Repo:** `/Users/alex/sandbox/amaranth-v2`.
- **Backlog:** `docs/implementation-tasks.json` (milestone "Q" text and T70–T73: context, deliverables, acceptance).
- **Overview:** `docs/release/UPDATES.md` (what each piece does, test commands).
- **Commits:** `git log 66570bb..HEAD` — T70 42d7068 (+ fix 2dad4c3), T71 d9e9df9, T72 99e2da3, then T73.
  Note: 99e2da3 also contains another session's unrelated spec 0009 / T97–T108 docs (swept in by mistake; ignore them).
- **Manual checklist:** `docs/qualification/ui-manual-checklist.md` item 88 (hands-on run on the second Mac).

## User decisions
- 2026-10-27: Release and Debug builds are both published; Debug is offered only with a Settings opt-in; a quiet note
  when a newer build exists, never an install the user didn't choose; no rollbacks.
- 2026-11-02: source = GitHub Releases on the public repo ATMartin/amaranth (zip + manifest.json per release; Debug as a
  prerelease; builds are public); publishing only when the user asks (`scripts/publish.sh`; `install-local.sh` stays
  local); checks at launch and from the menu only (no timer); the launch note is a toolbar button ("Update Available",
  arrow.down.circle) that opens the dialog and stays hidden after Later until the next launch.
- Run decisions 2026-11-02: I may push main and publish as many test releases as the end-to-end run needs (they stay
  up), and the end-to-end run may update `/Applications/Amaranth.app` in place when idle, ending on a Release build.
- Not notarized (free personal team): trust rests on the manifest sha256 plus the bundle ID + team ID + signature
  checks at install time.

## Ground rules
- Be adversarial and independent; check claims against code, tests, renders and the evidence.
- `<scratch>` = `/private/tmp/claude-501/-Users-alex-sandbox-amaranth-v2/aa5173c6-6fb8-4ce9-bf25-13e5b2c31ce2/scratchpad`.
- **Don't** modify source or docs; scratch files only under `<scratch>/validator/`. `rm` is aliased; use `/bin/rm -f`.
- **Don't** touch `/Applications/Amaranth.app`, `~/Library/Application Support/Amaranth`, the app's defaults
  (`com.alexmartin.amaranth`), GitHub releases/tags, or `git push`. Don't run `scripts/publish.sh` without
  `--local-only --dest <scratch>/validator/...`, `scripts/install-local.sh`, the `update-install` self-test,
  `xcodegen`/`xcodebuild` or `scripts/check.sh`. Another session works in this repo too: ignore uncommitted changes
  that aren't Milestone Q's.
- You may run:
  - `swift test --scratch-path <scratch>/validator/build --filter "Update|BuildInfo|Install|Recorded"`
  - `scripts/test-update-helper.sh`
  - `scripts/test-update-verify.sh build/DerivedData/Build/Products/Debug/Amaranth.app/Contents/MacOS/Amaranth <good build folder>`
    with `<scratch>/updates/debug/121` (a Debug build published with `--local-only`)
  - the Debug app's headless self-tests (temporary store; never the user's library):
    `build/DerivedData/Build/Products/Debug/Amaranth.app/Contents/MacOS/Amaranth --self-test <name> ...` for
    `ui-render-updates --self-test-output <scratch>/validator/png`, `update-check [--running-build N] [--include-debug]
    [--update-folder DIR]`, `update-verify [...] [--any-candidate --expect-reject]`. GitHub's unauthenticated API allows
    60 calls an hour from this address, so keep `update-check`/`update-verify` against GitHub to a handful.
  - `sandbox-exec -p '(version 1)(allow default)(deny network*)' <app binary> --self-test update-check --expect-error`
    (offline behaviour).
  - read-only `gh release list/view -R ATMartin/amaranth` and `curl -sL` of release assets.
- Evidence already gathered (read, don't re-run): `<scratch>/q-e2e/` (end-to-end log, update.log copies, before/after
  build info, library counts, toolbar/window screenshots where available) and `<scratch>/upd-ui/` (renders).

## What to judge
1. **T70 build numbers and publishing**: the stamp phase runs for the app and the worker in every build path, before
   signing, without user-script sandboxing problems; a stale stamp is refused; `--build-info`; `publish.sh` refuses a
   dirty tree, an unpushed HEAD and an existing tag; zip first, manifest last; manifest fields and sha256 match the zip;
   `--local-only` staging rename; `build-release.sh` and `install-local.sh` still behave as before (DMG, team check,
   recording refusal). Bash 3.2 / `set -u` / `pipefail` pitfalls (empty arrays, SIGPIPE).
2. **T71 checking**: UpdateCatalog rules (channels, ties, equal/older, other team, other app, malformed manifests,
   macOS); GitHub source (release list once, no cache, ≤5 manifests, drafts, assets still uploading, missing zip,
   tag/manifest mismatch, rate limit, offline, blocked connection, never retried in a loop); local folder layout;
   launch check (once, after launch, never on a timer, never shown while recording, quiet on failure); menu item and
   window states; Settings → Updates (source, folder bookmark, Debug opt-in, check at launch, Check Now); the toolbar
   note keeps the sun/moon and Ask toggles at the end of the toolbar at 900 and 1100 pt.
3. **T72 installing**: refused while recording and outside /Applications; download into the same volume, progress and
   Cancel; size + sha256 before unzip; signature (deep, strict, nested), bundle ID, team ID, arm64, minimum macOS, build
   and channel before anything is replaced; quarantine cleared only after the checks; the helper waits for the exact
   PID, swaps, restores on failure, deletes the old app, relaunches with `--updated-from` / `--update-failed`; notes are
   saved on quit; processing resumes after the relaunch (JobScheduler.start requeues running jobs); no rollbacks; what
   happens if quitting is cancelled, if the download is interrupted, if `/Applications` isn't writable, if two installs
   are started.
4. **T73 end-to-end** (evidence): GitHub Release N → N+1 in the real app (library intact, same signing identity so the
   microphone/system-audio grants carry), Debug opt-in, a local folder, rejection of a release without a manifest, a
   sha256 mismatch, a build from another team and an older build, the launch note, offline behaviour, a failed swap that
   leaves the old app working.
5. Regressions: the main toolbar, Settings tabs, launch with no network, self-tests listed in check.sh.

Write your verdict to `<scratch>/validator/verdict-v1.md`: PASS / PASS WITH FIXES / FAIL, then must-fix items (with
file:line and a concrete failure scenario), should-fix items, and what you verified yourself versus took from evidence.
