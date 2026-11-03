import AppKit
import SwiftUI
import Storage
import Presentation

/// Milestone Q self-tests.
/// `Amaranth --self-test ui-render-updates --self-test-output <dir>`: the Software Update window in each state, the
/// toolbar note in the real (bridged) main toolbar at 900 and 1100 pt, and Settings → Updates, in light and dark.
/// `Amaranth --self-test update-check [--update-folder <dir>] [--include-debug] [--running-build <N>]`: one real check
/// against GitHub (or the folder) as the given build, logging what would be offered. Reads nothing of the user's.
/// `Amaranth --self-test update-verify [same options] [--expect-reject]`: T72's download and checks (size, sha256, unzip,
/// signature, bundle ID, team, arm64, macOS, build, channel) for the offered build, into a temporary folder. Never
/// replaces or launches anything.
enum UpdateSelfTest {
    static func arg(_ k: String) -> String? {
        let a = CommandLine.arguments
        return a.firstIndex(of: k).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil }
    }

    @MainActor static func check() async -> Bool {
        let running = BuildInfo.running
        let build = arg("--running-build").flatMap(Int.init) ?? running.build
        let model = UpdateModel(running: BuildInfo(version: running.version, build: build, commit: running.commit, channel: running.channel))
        let includeDebug = CommandLine.arguments.contains("--include-debug")
        let source: any UpdateSource = arg("--update-folder").map { LocalFolderSource(folder: URL(filePath: $0)) } ?? GitHubReleasesSource()
        SelfTest.log(["step": "check", "running": "\(build)", "team": model.teamID ?? "none", "debug": "\(includeDebug)",
                      "source": arg("--update-folder") ?? "github"])
        do {
            let found = try await source.candidates(above: build, includeDebug: includeDebug)
            for c in found {
                SelfTest.log(["step": "candidate", "build": "\(c.manifest.build)", "channel": c.manifest.channel, "team": c.manifest.teamID,
                              "download": c.download.absoluteString])
            }
            let pick = UpdateCatalog.newest(found, running: model.running, bundleID: Bundle.main.bundleIdentifier ?? "", teamID: model.teamID,
                                            includeDebug: includeDebug, systemVersion: ProcessInfo.processInfo.operatingSystemVersion)
            SelfTest.log(["step": "offer", "build": pick.map { "\($0.manifest.build)" } ?? "none", "channel": pick?.manifest.channel ?? ""])
            return true
        } catch {
            SelfTest.log(["step": "error", "error": "\(error)", "message": error.message])
            return CommandLine.arguments.contains("--expect-error")
        }
    }

    @MainActor static func verify() async -> Bool {
        let running = BuildInfo.running
        let build = arg("--running-build").flatMap(Int.init) ?? running.build
        let model = UpdateModel(running: BuildInfo(version: running.version, build: build, commit: running.commit, channel: running.channel))
        let includeDebug = CommandLine.arguments.contains("--include-debug")
        let source: any UpdateSource = arg("--update-folder").map { LocalFolderSource(folder: URL(filePath: $0)) } ?? GitHubReleasesSource()
        let expectReject = CommandLine.arguments.contains("--expect-reject")
        // The catalog normally hides other-team or malformed builds; --any-candidate takes the newest manifest as is, so a
        // bad build reaches the install-time checks.
        let found: [UpdateCandidate]
        do { found = try await source.candidates(above: build, includeDebug: includeDebug) }
        catch { SelfTest.log(["step": "check", "error": error.message]); return false }
        let pick = CommandLine.arguments.contains("--any-candidate") ? found.max { $0.manifest.build < $1.manifest.build }
            : UpdateCatalog.newest(found, running: model.running, bundleID: Bundle.main.bundleIdentifier ?? "", teamID: model.teamID,
                                   includeDebug: includeDebug, systemVersion: ProcessInfo.processInfo.operatingSystemVersion)
        guard let pick else { SelfTest.log(["step": "offer", "build": "none"]); return false }
        model.stagingURL = FileManager.default.temporaryDirectory.appending(path: "amaranth-update-verify-\(UUID())")
        defer { model.cleanUpStaging() }
        SelfTest.log(["step": "offer", "build": "\(pick.manifest.build)", "channel": pick.manifest.channel, "download": pick.download.absoluteString])
        let t0 = ContinuousClock.now
        do {
            let app = try await model.prepare(pick)
            let facts = UpdateModel.facts(of: app)
            SelfTest.log(["step": "verified", "build": "\(facts.build ?? 0)", "team": facts.teamID ?? "none", "archs": facts.architectures.joined(separator: ","),
                          "seconds": String(format: "%.1f", (ContinuousClock.now - t0) / .seconds(1))])
            return !expectReject
        } catch {
            SelfTest.log(["step": "rejected", "reason": (error as? UpdateModel.InstallError)?.message ?? "\(error)"])
            return expectReject
        }
    }

    /// `Amaranth --self-test update-install [same options] [--fail-swap]`, run as /Applications/Amaranth.app's binary while
    /// the app is NOT open: the whole in-app update except the button (download, checks, helper), then this process exits
    /// and the helper swaps the bundles and opens the app with --updated-from (or, with --fail-swap, makes the swap fail so
    /// the old app must come back and open with --update-failed). Validation only (Milestone Q).
    @MainActor static func install() async -> Bool {
        guard Bundle.main.bundleURL.standardizedFileURL.path == UpdateModel.installedURL.path else {
            SelfTest.log(["step": "location", "error": "run /Applications/Amaranth.app/Contents/MacOS/Amaranth"]); return false
        }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard others.isEmpty else { SelfTest.log(["step": "running", "error": "quit Amaranth first"]); return false }
        let running = BuildInfo.running
        let model = UpdateModel(running: running)
        let includeDebug = CommandLine.arguments.contains("--include-debug")
        let source: any UpdateSource = arg("--update-folder").map { LocalFolderSource(folder: URL(filePath: $0)) } ?? GitHubReleasesSource()
        let found: [UpdateCandidate]
        do { found = try await source.candidates(above: running.build, includeDebug: includeDebug) }
        catch { SelfTest.log(["step": "check", "error": error.message]); return false }
        guard let pick = UpdateCatalog.newest(found, running: running, bundleID: Bundle.main.bundleIdentifier ?? "", teamID: model.teamID,
                                              includeDebug: includeDebug, systemVersion: ProcessInfo.processInfo.operatingSystemVersion) else {
            SelfTest.log(["step": "offer", "build": "none", "running": "\(running.build)"]); return false
        }
        SelfTest.log(["step": "offer", "build": "\(pick.manifest.build)", "channel": pick.manifest.channel, "running": "\(running.build)"])
        do {
            let app = try await model.prepare(pick)
            let env = CommandLine.arguments.contains("--fail-swap") ? ["AMARANTH_HELPER_FAIL_SWAP": "1"] : [:]
            try model.startHelper(newApp: app, build: pick.manifest.build, environment: env)
            SelfTest.log(["step": "helper-started", "log": UpdateModel.logURL.path])
            return true
        } catch {
            model.cleanUpStaging()
            SelfTest.log(["step": "rejected", "reason": (error as? UpdateModel.InstallError)?.message ?? "\(error)"])
            return false
        }
    }

    @MainActor static func render() async -> Bool {
        _ = NSApplication.shared
        let temp = FileManager.default.temporaryDirectory.appending(path: "amaranth-update-ui-\(UUID())")
        defer { try? FileManager.default.removeItem(at: temp) }
        let out = arg("--self-test-output").map { URL(filePath: $0) } ?? temp.appending(path: "png")
        guard let store = try? MeetingStore(root: temp.appending(path: "store")) else { return false }
        let suiteName = "amaranth-ui-render-updates"
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "onboarded")

        let running = BuildInfo(version: "0.1.0", build: 122, commit: "42d7068", channel: .release)
        let updates = UpdateModel(running: running, teamID: "WLKNK4P84Z", arguments: [])
        updates.allowAnyLocation = true
        let m = UpdateManifest(bundleID: "com.alexmartin.amaranth", version: "0.1.0", build: 125, commit: "9f3e2a1", channel: "release",
                               asset: "Amaranth-0.1.0-125.zip", size: 41_500_000, sha256: String(repeating: "0", count: 64), teamID: "WLKNK4P84Z",
                               minimumSystemVersion: "26.5.2", schemaVersion: 6,
                               changes: ["T72: install and relaunch from inside the app.", "T71: Check for Updates… (menu, launch check, Settings → Updates).",
                                         "Transcript: right-clicking a line's text opens the row menu, not the system text menu."])
        let candidate = UpdateCandidate(manifest: m, download: URL(string: "https://example.invalid/a.zip")!)
        let worker = WorkerClient()
        let models = ModelSetupModel()
        let recorder = RecorderModel(store: store, recover: false)
        updates.recorder = recorder
        let library = LibraryModel(store: store)
        let playback = PlaybackModel()
        let live = LiveTextModel(client: worker)
        let calendar = CalendarModel(source: FakeCalendarSource(status: .notDetermined))
        var ok = true

        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = NSAppearance(named: appearanceName)!
            let dir = out.appending(path: name)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            func shoot<V: View>(_ v: V, _ file: String, size: CGSize?) async {
                let view = NSHostingView(rootView: v.defaultAppStorage(defaults).environment(updates))
                view.appearance = appearance
                let fit = size ?? view.fittingSize
                view.frame = CGRect(origin: .zero, size: fit)
                let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = appearance
                window.contentView = view
                try? await Task.sleep(for: .milliseconds(300))
                view.layoutSubtreeIfNeeded()
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "\(file).png"))
                SelfTest.log(["step": "render", "file": "\(name)/\(file).png", "size": "\(Int(fit.width))x\(Int(fit.height))"])
            }
            let phases: [(String, UpdateModel.Phase)] = [
                ("available", .available(candidate)), ("up-to-date", .upToDate), ("checking", .checking),
                ("offline", .failed(UpdateCheckError.offline.message)),
                ("rate-limited", .failed(UpdateCheckError.rateLimited(until: nil).message)),
            ]
            for (file, phase) in phases {
                updates.phase = phase
                await shoot(UpdateWindow(updates: updates), "update-\(file)", size: nil)
            }
            // T72: installing, and the reasons it won't.
            updates.phase = .available(candidate)
            let installs: [(String, UpdateModel.InstallPhase, Bool)] = [
                ("downloading", .downloading(0.42), true), ("verifying", .verifying, true),
                ("rejected", .failed("Build 125 wasn't installed: It's signed by team ZZZZZZZZZZ, not this app's team (WLKNK4P84Z). Nothing was changed."), true),
                ("not-in-applications", .idle, false),
            ]
            for (file, phase, anywhere) in installs {
                updates.installPhase = phase
                updates.allowAnyLocation = anywhere
                await shoot(UpdateWindow(updates: updates), "update-install-\(file)", size: nil)
            }
            updates.installPhase = .idle
            updates.allowAnyLocation = true
            let failedAfter = UpdateModel(running: running, teamID: "WLKNK4P84Z", arguments: ["--update-failed", "125"])
            await shoot(UpdateWindow(updates: failedAfter), "update-install-failed-relaunch", size: nil)
            for (file, source) in [("github", UpdateSettings.Source.github), ("folder", .folder), ("off", .off)] {
                defaults.set(source.rawValue, forKey: UpdateSettings.sourceKey)
                if source == .folder { defaults.set("/Volumes/Shared/Amaranth Updates", forKey: UpdateSettings.folderPathKey) }
                await shoot(UpdateSettingsView(updates: updates), "settings-updates-\(file)", size: CGSize(width: 560, height: 640))
            }
            defaults.removeObject(forKey: UpdateSettings.sourceKey)

            // The toolbar note in the real main toolbar, at 900 and 1100 pt: present while a newer build is known, gone
            // after Later and while recording; the sun/moon and Ask toggles still end the toolbar.
            for width in [900.0, 1100.0] {
                for (state, setup) in [("available", { updates.phase = .available(candidate); updates.noteDismissed = false }),
                                       ("later", { updates.noteDismissed = true }),
                                       ("none", { updates.phase = .upToDate; updates.noteDismissed = false }),
                                       ("updated", { updates.updatedFrom = 122 })] as [(String, () -> Void)] {
                    setup()
                    let size = CGSize(width: width, height: 640)
                    let view = NSHostingView(rootView: MainView().defaultAppStorage(defaults).environment(worker).environment(models)
                        .environment(recorder).environment(library).environment(playback).environment(live).environment(calendar)
                        .environment(updates).frame(width: size.width, height: size.height))
                    view.sceneBridgingOptions = [.toolbars]
                    let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 40, y: 40), size: size), styleMask: [.titled, .resizable],
                                          backing: .buffered, defer: false)
                    window.appearance = appearance
                    window.contentView = view
                    // On screen briefly: offscreen windows don't place items the way the real window does.
                    window.orderFrontRegardless()
                    try? await Task.sleep(for: .milliseconds(700))
                    let items = window.toolbar?.items ?? [], visible = window.toolbar?.visibleItems ?? []
                    let labels = items.map { $0.label.isEmpty ? $0.itemIdentifier.rawValue : $0.label }
                    let expected = state == "available" ? "Update Available" : state == "updated" ? "Updated to build 122" : nil
                    let note = items.first { $0.label.hasPrefix("Update") }
                    let noteVisible = note.map { n in visible.contains { $0 === n } } ?? false
                    let endsRight = labels.suffix(2).first?.hasPrefix("Switch to") == true && labels.last?.hasSuffix("Ask") == true
                    let pass = endsRight && (expected.map { note?.label == $0 && noteVisible } ?? (note == nil))
                    SelfTest.log(["step": "toolbar-note", "appearance": name, "width": "\(Int(width))", "state": state,
                                  "items": labels.joined(separator: " | "), "noteVisible": "\(noteVisible)", "ok": "\(pass)"])
                    if !pass { ok = false }
                    if let frameView = window.contentView?.superview {
                        let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)!
                        frameView.cacheDisplay(in: frameView.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "toolbar-note-\(Int(width))-\(state).png"))
                    }
                    window.orderOut(nil)
                    window.contentView = nil
                }
                updates.updatedFrom = nil
            }
        }
        SelfTest.log(["step": "output", "directory": out.path])
        return ok
    }
}
