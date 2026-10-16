# Models 0002: Model pack install, verification and activation (T04)

Date: 2026-10-16 · Task: T04 · Status: Accepted (mechanism). Pack *contents* follow models/0001.

## Decision

- **Pack definition:** a `ModelPack` (Domain contract v1) lists one `ModelManifest` per model. Each manifest records:
  - the exact repository and immutable revision;
  - every file's path, sha256, byte size and pinned `resolve/<sha>/` URL;
  - conversion provenance and tokenizer/template identity;
  - license identifier, notice path and attribution;
  - minimum OS.

  `validatePinning()` rejects `main`/`latest` and files without a sha256. The installer also rejects absolute paths, `..`
  paths, and manifests whose minimum OS is newer than the running system.
  Packs are generated from `ModelStore/*/manifest.json` with `amaranth-models build-pack`. The primary provenance is the
  repo of the weights file, not a LICENSE copied alongside it.
- **Layout:** `~/Library/Application Support/Amaranth/Models/`, outside cloud-synced Documents:
  - `packs/<id>/<version>/<manifestID>/…` is immutable once activated.
  - `staging/<id>-<version>/` holds in-progress installs. Its name is stable, so an interrupted install resumes.
  - `active.json` is replaced atomically (temp file + `rename(2)`).
  - `leases/*.lease` holds a pid-stamped lease per running job. Leases from dead processes are reaped.
- **Install** (`ModelInstaller`):
  1. Check free space: remaining bytes plus a 1 GB margin, kept separate from recording space.
  2. Fetch each file into `<file>.partial`, appending from the current size (HTTP `Range`, or a file offset for imports).
  3. Check the size, then sha256. A mismatch **deletes** the partial file, so corrupt bytes are never kept or activated.
  4. Rename to the final name and write `pack.json`.
  5. Run an optional warm-up (Core ML load / sample) against the staged pack.
  6. `rename` the whole staging directory into `packs/`, then flip `active.json`.

  Re-installing an existing version first runs a full verification of the installed copy. If it verifies, the
  installer just reactivates it with no download. If any file is damaged, the installer stages a fresh copy and swaps it
  in atomically (`renamex_np(RENAME_SWAP)`), so the pack path never disappears. The damaged copy is then deleted. A
  damaged pack that a running job has leased is not modified (`packInUse`). This is the repair path behind the UI's
  "reinstall / import".
- **Sources:**
  - `HTTPModelSource` accepts only https `sourceURL`s that are pinned revisions. It resumes with `Range`. If a server
    ignores `Range` (HTTP 200), it truncates the partial and restarts that file from zero.
  - `DirectoryModelSource` is the offline import of the same manifest and files from `<manifestID>/<path>`.
    `ModelStore/` itself is a valid import directory.
  - **No other code path downloads.**
- **Inference-side resolution:** `LocalModelRegistry` has no network code (enforced by a test that greps the source).
  - `.sizes` checks existence and byte size before each job; `.fullHash` checks sha256 on demand.
  - A missing or corrupt file is reported as `corrupt(manifest, path)` or `notInstalled`. Nothing is repaired automatically.
  - The app shows **record-only** and offers reinstall or import. Other models in the pack stay resolvable.
- **Upgrade:** a pack version used by a running job (leased) is never removed. Activating v2 leaves v1 on disk until its
  lease is released.
- **Runtime download hazards neutralised:**
  - FluidAudio: `ModelHub.offlineMode = true` is set before any load. ASR uses `AsrModels.loadLocal`.
  - The offline diarizer is constructed by hand from the four `.mlmodelc` files plus our own decode of PLDA ψ.
    This avoids `ModelHub` folder remapping, revision-marker checks, and `prepareModels()`, which deletes the model
    directory on a failed load even in offline mode.
  - WhisperKit gets `download: false` **and** an explicit `tokenizerFolder`; otherwise it fetches the tokenizer.
  - llama.cpp loads a local GGUF only.

## Evidence

- `swift test --filter ModelsTests` (9 tests):
  - fresh install → active → full-hash `ready`;
  - an interrupted install never activates and resumes exactly the missing bytes;
  - a corrupt source is rejected and its partial deleted;
  - insufficient space is reported before downloading;
  - floating revisions, path escapes and newer-OS manifests are rejected;
  - post-install corruption is detected (same-size bit flip by `.fullHash`, truncation by `.sizes`) with no repair, and
    other models stay usable;
  - a leased old version survives an upgrade and can't be removed until released; the active pack can't be removed;
  - cancellation leaves nothing active;
  - the registry source has no network code.
- `RepairAndHTTPTests` (5 more tests, 14 total):
  - a corrupt same-version pack is repaired by reinstall, with its bytes restored;
  - an intact reinstall activates without fetching;
  - a damaged leased pack is not modified;
  - an HTTP interrupt resumes with `Range`;
  - an HTTP server that ignores `Range` restarts the file cleanly (mock `URLProtocol`).
- **Real HTTPS install of the full default pack (3.00 GB)**, interrupted with `kill -9` after 25 s, which left 496 MB of
  partial files: nothing activated. The second attempt resumed and finished in 101 s, then `verify --full` reported
  `ready`. Log: `evidence/2026-10-16/https-full-pack-install-interrupted-resumed.log`.
- Every shipped model now carries a license or notice file (pack 0.1.1).
- `App/ModelSetup`: first-run screen with download size, free space needed and available, per-model license and
  attribution, progress, cancel, import from folder, and a record-only state.
- Offline sample transcript and summary verification of the installed default pack: `evidence/2026-10-16/verify-pack-offline.txt`
  (`verify-pack` under `sandbox-exec` with networking denied; curl shows DNS blocked).
- **Not yet wired:** the app's installer passes no warm-up hook, so the Core ML first-load compile (16 s for v3) falls on
  the first job. Worker-side offline enforcement is verified only in the bench engines and the registry grep test. Both
  must be re-verified when the real engines move into the XPC worker (T06–T08).
