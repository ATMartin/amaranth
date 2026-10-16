# 0001 — Project layout, toolchain, bundle identity and signing

Date: 2026-10-15 · Task: T01 · Status: Accepted

## Decision

- **Toolchain:** Xcode 26.6 (17F113), Apple Swift 6.3.3, Swift 6 language mode with complete strict concurrency.
  Swift Testing for tests. Built and tested on macOS 26.5.2 (25F84), M2 Max.
- **Deployment floor:** `MACOSX_DEPLOYMENT_TARGET = 26.5` (the build setting cannot express a patch level),
  `LSMinimumSystemVersion = 26.5.2` in both Info.plists, plus a full runtime check
  (`OSVersionGate`, which requires 26.5.2 and arm64) at launch. No later-only APIs for core features.
- **Architecture:** arm64 only.
- **Frozen bundle IDs:** app `com.alexmartin.amaranth`, XPC worker `com.alexmartin.amaranth.InferenceWorker`
  (constants in `Domain/Worker/WorkerIPC.swift`). Do not change them: TCC microphone and system-audio grants bind to them.
- **Layout:** one root `Package.swift` (AmaranthKit) whose targets map onto the plan's module ownership directories
  (`Domain/`, `Capture/`, `Storage/`, … `Tests/<Area>/`). `project.yml` (xcodegen 2.45.3) generates the
  app and the bundled `xpc-service` target. The generated `.xcodeproj` is not committed.
- **Process boundary:** the app owns capture, storage and the DB writer. ML runs in the bundled XPC worker (NSXPC,
  JSON-encoded `Versioned<WorkerRequest/Response>` capped at 1 MiB per message). Worker crashes
  surface through `interruptionHandler`. A worker that hangs past the request timeout gets SIGKILL
  (its pid comes from `pong`) before the request fails, so the next request reaches a fresh worker.
- **Signing:** no identity exists on the build machine yet, so builds use ad-hoc signing
  (`CODE_SIGN_IDENTITY = -`) with hardened runtime and the `com.apple.security.device.audio-input` entitlement.
  The user will add a free Apple ID team. Set it in `Config/Signing.local.xcconfig` (gitignored; see the
  `.example`). Until then, TCC may re-prompt after rebuilds. Notarization (T13) needs a paid team and is
  marked incomplete until one exists.
- **No sandbox** for v0 (direct-download app; the plan does not require it). Revisit in T13.

## Evidence

`scripts/check.sh` runs the contract tests, generates and builds the app and worker, then runs the
bundle self-tests:
- `--self-test os-gate`: runtime floor and architecture.
- `--self-test worker-crash`: worker `abort()`s mid-request; the app observes the interruption, keeps
  running, gets a pong from a relaunched worker with a different pid, and completes a fake job.
- `--self-test worker-hang`: a hung worker is detected by timeout, killed and replaced.

The first crash self-test found a real defect: XPC error and interruption closures inherited
`@MainActor` isolation and trapped (`dispatch_assert_queue`) when XPC invoked them off-main.
They are now `@Sendable`. Keep this in mind for every Core Audio and XPC callback.
