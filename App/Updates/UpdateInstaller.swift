import Foundation
import AppKit
import Security
import Presentation

/// Install and Relaunch (T72). The download is staged on the same volume as the installed app, checked against the
/// manifest (size, sha256), unzipped with ditto and verified (signature, bundle ID, team ID, arm64, minimum macOS, build
/// number, channel) before anything is replaced. Then the embedded update-helper.sh waits for this process to quit,
/// swaps the bundles (restoring the old one on failure), deletes the old one and relaunches with --updated-from <build>.
/// No rollbacks (user decision 2026-10-27).
extension UpdateModel {
    static let installedURL = URL(filePath: "/Applications/Amaranth.app")
    /// Hidden, beside the installed app, so the swap is a rename on one volume.
    static let defaultStagingURL = URL(filePath: "/Applications/.Amaranth-update")
    static let logURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Amaranth/update.log")

    /// Why Install and Relaunch can't run now, or nil.
    var installBlocker: String? {
        if recorder?.inSession == true { return "Amaranth is recording. Stop the recording, then install; nothing is lost by waiting." }
        let here = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath().path
        if here != Self.installedURL.path && !allowAnyLocation {
            return "This copy of Amaranth runs from \(here), not /Applications, so it can't replace itself. Install the update by hand or with scripts/install-local.sh."
        }
        return nil
    }

    func install(_ c: UpdateCandidate) {
        guard installTask == nil else { return }
        if let blocker = installBlocker { installPhase = .failed(blocker); return }
        stopHelper()
        installPhase = .downloading(nil)
        installTask = Task { [weak self] in
            guard let self else { return }
            do {
                let app = try await self.prepare(c)
                // Recording might have started during the download.
                if let blocker = self.installBlocker { throw InstallError(blocker) }
                try Task.checkCancellation()   // Cancel while "Checking the download…" must stop here
                try self.startHelper(newApp: app, build: c.manifest.build)
                self.installPhase = .relaunching
                self.installTask = nil
                // The notes editor saves on willTerminate (NotesPane); the recorder's quit guard doesn't apply (not recording).
                NSApp.terminate(nil)
                // Still here a few seconds later: quitting was cancelled (a recording started and "Keep Recording" was
                // chosen). The helper gives up on its own after 60 s and changes nothing; let the dialog say so.
                try? await Task.sleep(for: .seconds(5))
                if self.installPhase == .relaunching {
                    self.stopHelper()
                    self.cleanUpStaging()
                    self.installPhase = .failed("Amaranth didn't quit, so the update wasn't installed. Nothing was changed; try again later.")
                }
            } catch is CancellationError {
                self.cleanUpStaging()
                self.installPhase = .idle
                self.installTask = nil
            } catch {
                self.cleanUpStaging()
                self.installPhase = .failed((error as? InstallError)?.message ?? "The update couldn't be installed: \(error.localizedDescription)")
                self.installTask = nil
            }
        }
    }

    func cancelInstall() {
        downloadTask?.cancel()
        installTask?.cancel()
    }

    struct InstallError: Error { let message: String; init(_ m: String) { message = m } }

    /// Download → size + sha256 → unzip → verify. Returns the verified Amaranth.app inside the staging folder.
    func prepare(_ c: UpdateCandidate) async throws -> URL {
        let fm = FileManager.default
        cleanUpStaging()
        do { try fm.createDirectory(at: stagingURL, withIntermediateDirectories: false) }
        catch { throw InstallError("Amaranth can't write to /Applications, so it can't update itself (\(error.localizedDescription)).") }
        let zip = stagingURL.appending(path: c.manifest.asset)
        try await download(c.download, to: zip, expected: c.manifest.size)
        try Task.checkCancellation()
        installPhase = .verifying
        let m = c.manifest
        let size = (try? fm.attributesOfItem(atPath: zip.path)[.size] as? Int64) ?? -1
        guard size == m.size else { throw InstallError("The download is incomplete (\(size) of \(m.size) bytes). Nothing was changed; try again.") }
        let sum = try await Task.detached { try FileDigest.sha256(of: zip) }.value
        try Task.checkCancellation()
        guard sum == m.sha256.lowercased() else {
            throw InstallError("The download doesn't match the published checksum, so it wasn't installed. Nothing was changed.")
        }
        let unzipped = stagingURL.appending(path: "unzipped")
        guard try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unzipped.path]) == 0 else {
            throw InstallError("The download couldn't be unzipped. Nothing was changed.")
        }
        try Task.checkCancellation()
        try? fm.removeItem(at: zip)
        let app = unzipped.appending(path: "Amaranth.app")
        guard fm.fileExists(atPath: app.path) else { throw InstallError("The download doesn't contain Amaranth.app. Nothing was changed.") }
        let facts = await Task.detached { Self.facts(of: app) }.value
        try Task.checkCancellation()
        let problems = UpdateBundleCheck.problems(facts, manifest: m, runningBundleID: Bundle.main.bundleIdentifier ?? "",
                                                  runningTeamID: teamID, systemVersion: ProcessInfo.processInfo.operatingSystemVersion)
        guard problems.isEmpty else {
            throw InstallError("Build \(m.build) wasn't installed: " + problems.joined(separator: " ") + " Nothing was changed.")
        }
        // Only after every check passed. Downloads by URLSession aren't quarantined today; this keeps it that way if they are.
        _ = try? await Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    private func download(_ url: URL, to dest: URL, expected: Int64) async throws {
        if url.isFileURL {   // a local folder source
            do { try FileManager.default.copyItem(at: url, to: dest) }
            catch { throw InstallError("The build couldn't be copied from the updates folder (\(error.localizedDescription)).") }
            installPhase = .downloading(1)
            return
        }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        defer { downloadTask = nil }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                let task = GitHubReleasesSource.session.downloadTask(with: request) { tmp, response, error in
                    if let error {
                        let e = error as? URLError
                        cont.resume(throwing: e?.code == .cancelled ? CancellationError()
                                    : InstallError("The download failed: \(GitHubReleasesSource.map(error).message) Nothing was changed."))
                        return
                    }
                    guard let tmp, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        cont.resume(throwing: InstallError("The download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)). Nothing was changed."))
                        return
                    }
                    do { try FileManager.default.moveItem(at: tmp, to: dest); cont.resume() } catch { cont.resume(throwing: error) }
                }
                downloadTask = task
                if Task.isCancelled { task.cancel() }   // Cancel arrived before the task existed
                task.resume()
                // Progress for the dialog, polled (no delegate needed).
                Task { @MainActor [weak self, weak task] in
                    while let task, task.state == .running {
                        let done = task.countOfBytesReceived
                        let total = task.countOfBytesExpectedToReceive > 0 ? task.countOfBytesExpectedToReceive : expected
                        if case .downloading = self?.installPhase { self?.installPhase = .downloading(total > 0 ? Double(done) / Double(total) : nil) }
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in self.downloadTask?.cancel() }
        }
    }

    /// Copies the embedded helper next to the staged build and starts it; it outlives this process.
    func startHelper(newApp: URL, build: Int, environment: [String: String] = [:]) throws {
        guard let bundled = Bundle.main.url(forResource: "update-helper", withExtension: "sh") else {
            throw InstallError("This build is missing its update helper. Nothing was changed.")
        }
        let helper = stagingURL.appending(path: "update-helper.sh")
        try? FileManager.default.removeItem(at: helper)
        try FileManager.default.copyItem(at: bundled, to: helper)
        let p = Process()
        p.executableURL = URL(filePath: "/bin/sh")
        p.arguments = [helper.path, "\(ProcessInfo.processInfo.processIdentifier)", newApp.path, Self.installedURL.path, "\(build)",
                       "\(running.build)", stagingURL.path, Self.logURL.path]
        // Never inherit the helper's test hooks (a relaunched app gets the helper's environment from `open`); only a
        // self-test passes them on purpose.
        p.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("AMARANTH_HELPER_") }.merging(environment) { $1 }
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        helperProcess = p
        do { try p.run() } catch { helperProcess = nil; throw InstallError("The update helper couldn't start (\(error.localizedDescription)). Nothing was changed.") }
    }

    /// Stops a helper still waiting for this process to quit (a vetoed quit), before anything reuses the staging folder.
    func stopHelper() {
        if let p = helperProcess, p.isRunning { p.terminate(); p.waitUntilExit() }
        helperProcess = nil
    }

    func cleanUpStaging() {
        try? FileManager.default.removeItem(at: stagingURL)
    }

    /// Signature (deep, strict), identity and Info.plist facts of a bundle on disk.
    nonisolated static func facts(of app: URL) -> UpdateBundleFacts {
        var valid = false
        var code: SecStaticCode?
        if SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code {
            let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
            valid = SecStaticCodeCheckValidityWithErrors(code, flags, nil, nil) == errSecSuccess
        }
        let bundle = Bundle(url: app)
        let info = bundle?.infoDictionary ?? [:]
        let archs = (bundle?.executableArchitectures ?? []).compactMap { n -> String? in
            switch n.intValue {
            case NSBundleExecutableArchitectureARM64: "arm64"
            case NSBundleExecutableArchitectureX86_64: "x86_64"
            default: nil
            }
        }
        return UpdateBundleFacts(signatureValid: valid, bundleID: bundle?.bundleIdentifier, teamID: CodeIdentity.teamID(of: app),
                                 build: (info["CFBundleVersion"] as? String).flatMap(Int.init), channel: info["AmaranthChannel"] as? String,
                                 minimumSystemVersion: info["LSMinimumSystemVersion"] as? String, architectures: archs)
    }

    nonisolated static func run(_ tool: String, _ args: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(filePath: tool)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}
