# Updates (Milestone Q)

How builds get from this repository to an installed Amaranth without copying DMGs between Macs.

## Build numbers (T70)

Every build is stamped by `scripts/stamp-build.sh` (an Xcode build phase on the app and the XPC worker):

| Info.plist key | Value |
| --- | --- |
| `CFBundleVersion` | git commit count of HEAD: one number line for Release and Debug, so higher = later commit |
| `AmaranthCommit` | short commit |
| `AmaranthDirty` | true when tracked files differed from HEAD |
| `AmaranthBuildDate` | UTC, ISO 8601 |
| `AmaranthChannel` | `release` or `debug` |

`Amaranth.app/Contents/MacOS/Amaranth --build-info` prints these plus the library schema version as JSON.
`scripts/build-app.sh` (used by `build-release.sh`, `install-local.sh` and `publish.sh`) refuses a stale stamp.

## Publishing (only when asked)

```
scripts/publish.sh            # Release → GitHub release build-<N> on ATMartin/amaranth
scripts/publish.sh --debug    # Debug → prerelease build-<N>-debug
scripts/publish.sh --local-only [--debug] [--dest DIR]   # DIR/<channel>/<N>/ (default dist/updates)
```

It refuses a working tree with any change, a HEAD that isn't on origin (it never pushes) and a tag that already
exists. It uploads the zip first and `manifest.json` last; the app ignores a release without a manifest, so a
half-finished publish is never offered. Releases are public: anyone can download the builds.

`manifest.json`: format, bundle ID, version, build, commit (+ full sha), channel, date, asset (zip name), size, sha256,
team ID, minimum macOS, library schema version, commit subjects since the previous published build of the channel.

## Checking (T71)

- Amaranth ▸ Check for Updates… and, if Settings → Updates → Check when Amaranth opens is on (default), once at launch.
  No timer. A newer build shows an **Update Available** toolbar button (hidden after Later until the next launch, and
  while recording); a failed launch check shows nothing.
- Settings → Updates: GitHub (default) / a local folder (bookmark) / Off; Include Debug builds (off).
- Offered: the newest build above the running one; Release only unless Debug is included; at the same number Release
  wins; never the same or older build (no rollbacks), another team, another app, a malformed manifest, or a build for a
  newer macOS.
- GitHub: one unauthenticated API call (60/hour per address) plus up to 5 manifest downloads, no cache, no retries.
  Offline, timed out, rate limited and blocked connections each get a plain message.
- This is Amaranth's only network use besides model downloads; Off disables it (release qualification must allow
  for it).

## Installing (T72)

Install and Relaunch (refused while recording, and for a copy not running from /Applications):

1. Download into `/Applications/.Amaranth-update/` (same volume as the app), with progress and Cancel.
2. Check size and sha256 against the manifest, unzip with ditto, then verify the bundle: valid signature (deep,
   strict, nested code), same bundle ID and team ID as the running app, arm64, minimum macOS, build number and channel
   equal to the manifest's. Only then remove the quarantine attribute.
3. Start the embedded `update-helper.sh` and quit normally (the notes editor saves on quit). The helper waits for the
   process to exit (60 s, else it changes nothing), moves the old app aside, moves the new one in, restores the old
   one if that fails, deletes the old one (no rollbacks) and opens the app with `--updated-from <build>` (toolbar:
   "Updated to build N", once) or `--update-failed <build>` (toolbar: "Update Didn't Install").
4. Log: `~/Library/Logs/Amaranth/update.log`.

Processing that was queued or running picks up again after the relaunch: jobs live in the library, finished steps are
kept, and the step that was running starts over (JobScheduler.start requeues it).

## Tests

- `swift test --filter "Update|BuildInfo|Install"`: catalog rules, GitHub source against recorded responses
  (`Tests/UI/Fixtures`), local folder, install-time checks, sha256.
- `scripts/test-update-helper.sh` (in check.sh): swap, failed swap, missing build, an app that never quits.
- `scripts/test-update-verify.sh <app binary> <good build folder>`: checksum mismatch, truncated zip, build-number
  mismatch and an ad-hoc re-signed copy are each rejected; the untouched build verifies.
- App self-tests: `ui-render-updates`, `update-check`, `update-verify`, `update-install` (see App/Launch/UpdateSelfTest.swift).
