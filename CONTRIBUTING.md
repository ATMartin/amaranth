# Working on Amaranth

Amaranth is a macOS app written in Swift. Most of the logic lives in a Swift package so it can be tested without
launching the app; the app itself and a background worker are built with Xcode.

Much of this code was written with AI coding assistants, directed and reviewed by the maintainer. You'll see the
traces of that in comments: `T68` or `T110` are task numbers from the project's task list, and "Milestone Q" style
names are the phases those tasks were grouped into. "User decision" in a comment means the maintainer chose that
behaviour on purpose, and "spec 0009" style references point at design notes that aren't published. You don't need
any of them to work on the code.

## Build and test

You need Xcode 27 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) and an Apple
silicon Mac on macOS 26.5.2 or later.

| Command | What it does |
|---|---|
| `scripts/check.sh` | Runs every test, builds the app and the worker, and runs the app's self-tests. Run this before sending a change. It takes several minutes. |
| `swift test --filter <name>` | Runs part of the test suite. |
| `scripts/install-local.sh` | Builds a Release copy, puts it in `/Applications` and opens it. Add `--debug` for a Debug build. It refuses while a recording is in progress. |
| `scripts/build-release.sh` | Makes a DMG in `dist/`. |

Signing is optional but worth setting up: without a team, macOS asks for microphone permission again after every
rebuild, and the in-app updater won't install anything. Copy `Config/Signing.local.xcconfig.example` to
`Config/Signing.local.xcconfig` and set your Team ID. That file is ignored by git.

Turn on the commit hooks once with `git config core.hooksPath .githooks`. They run `scripts/privacy-scan.sh`, which
`scripts/check.sh` also runs first: it refuses secrets and private material (see the ground rules below).

Some checks need a person to answer a permission prompt (microphone, system audio, calendar). `scripts/check.sh`
lists them when it finishes.

## Where things are

| Folder | What's in it |
|---|---|
| `Domain/` | The shared types: meetings, transcripts, speakers, notes, jobs. No dependencies. |
| `Capture/` | Recording the microphone and system audio, writing audio to disk, and recovering after a crash. |
| `Storage/` | The library on disk: SQLite, search, deletion. |
| `Models/` | Downloading, verifying and installing the model packs. The pinned versions and hashes are in `Models/Packs/`. |
| `ASR/`, `Diarization/` | Speech to text, and working out who spoke. |
| `Notes/` | Writing the notes and answering questions with the local language model. |
| `Contextual/` | Finding the relevant parts of past meetings for a question. |
| `Export/`, `MeetingAccess/` | Export formats, and read-only access to meetings for other tools. |
| `InferenceWorker/` | The background process that runs the models, and the job scheduler that feeds it. |
| `Presentation/` | View logic that doesn't need a window, so it can be unit tested. |
| `App/` | The SwiftUI app. `App/Launch/` holds the self-tests the app can run from the command line. |
| `Tests/` | Unit tests, grouped by module. |
| `Benchmarks/` | The measurement harness and its public and synthetic test data. See `Benchmarks/README.md`. |
| `guides/` | Pages for people using the app. |

## Ground rules

- **Nothing leaves the Mac.** The only network use is downloading models and checking for updates. A change that
  adds another needs a very good reason and a setting to turn it off.
- **No real meeting content in the repository.** Tests, benchmarks, screenshots and examples use invented people,
  companies and conversations. Don't commit transcripts, notes, benchmark output or screenshots that come from a real
  library.
- **Recording comes first.** Nothing may interrupt or degrade a recording in progress: not processing, not an
  update, not a prompt.
- **Don't change the bundle identifiers.** Existing libraries and permissions are tied to them.

## Publishing a build

Publishing is the maintainer's job; this is here so the process is written down.

Every build is stamped with a build number and the commit it came from. `Amaranth.app/Contents/MacOS/Amaranth
--build-info` prints them. The number is the count of commits plus the base in `Config/build-number-base`, so a later
commit always has a higher number. Don't rewrite published history: it would hand out numbers that are already taken.

```sh
scripts/publish.sh                          # a Release build, as a GitHub release
scripts/publish.sh --debug                  # a Debug build, as a prerelease
scripts/publish.sh --local-only --dest DIR  # into a folder instead, for Settings → Updates → A local folder
```

The script refuses if there are uncommitted changes, if the commit hasn't been pushed, or if that build was already
published. It uploads the app first and its `manifest.json` last, and the app ignores a release without a manifest,
so a publish that stops half-way is never offered to anyone.

A fork that wants its own update channel sets `AMARANTH_UPDATE_REPOSITORY` in `Config/Base.xcconfig` (or in
`Config/Signing.local.xcconfig`) and `AMARANTH_REPO` when running `publish.sh`. The app only installs builds signed
by the same team as the running copy, so one project's builds can never replace another's.

How updates look from the user's side is in [guides/UPDATES.md](guides/UPDATES.md).
