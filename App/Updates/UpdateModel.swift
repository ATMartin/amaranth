import Foundation
import AppKit
import Security
import Presentation

/// Code signing facts read with the Security framework (no codesign process).
enum CodeIdentity {
    /// The team identifier a bundle is signed with, or nil (ad-hoc, unsigned or unreadable).
    static func teamID(of bundle: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    static let runningTeamID: String? = teamID(of: Bundle.main.bundleURL)
}

/// Check for Updates… (T71): the menu command, the launch check and its toolbar note, and the dialog. Checks happen at
/// launch (Settings → Updates → Check at launch) and when asked, never on a timer; a failed launch check stays quiet.
@MainActor @Observable
final class UpdateModel {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateCandidate)
        case failed(String)
    }

    var phase: Phase = .idle
    private(set) var lastChecked: Date?
    /// Later hides the toolbar note until the next launch.
    var noteDismissed = false
    let running: BuildInfo
    let teamID: String?
    weak var recorder: RecorderModel?
    /// Replaces the source from Settings (self-tests and renders).
    var sourceOverride: (any UpdateSource)?
    private var checkTask: Task<Void, Never>?

    // T72: Install and Relaunch (UpdateInstaller.swift).
    enum InstallPhase: Equatable {
        case idle
        case downloading(Double?)
        case verifying
        case relaunching
        case failed(String)
    }
    var installPhase: InstallPhase = .idle
    /// Where downloads are staged; self-tests point it at a temporary folder.
    var stagingURL = UpdateModel.defaultStagingURL
    /// Renders and self-tests only: skip the "runs from /Applications" rule.
    var allowAnyLocation = false
    var installTask: Task<Void, Never>?
    var downloadTask: URLSessionDownloadTask?
    /// The helper started for this install; stopped if quitting was vetoed, so a retry can't race its cleanup.
    var helperProcess: Process?
    /// Processing is queued or running (it picks up again after the relaunch; the step in progress starts over).
    var processingPending: () -> Bool = { false }
    /// This launch follows an in-app update from this build (`--updated-from`): the toolbar says so once.
    var updatedFrom: Int?
    /// The helper couldn't install this build (`--update-failed`); the old app was kept.
    var failedBuild: Int?

    init(running: BuildInfo = .running, teamID: String? = CodeIdentity.runningTeamID, arguments: [String] = CommandLine.arguments) {
        self.running = running; self.teamID = teamID
        func value(_ flag: String) -> Int? { arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? Int(arguments[$0 + 1]) : nil } }
        updatedFrom = value("--updated-from")
        failedBuild = value("--update-failed")
        if let failedBuild {
            phase = .failed("Build \(failedBuild) couldn't be installed, so Amaranth \(running.label) was kept as it was. Details are in ~/Library/Logs/Amaranth/update.log.")
        }
    }

    var available: UpdateCandidate? { if case .available(let c) = phase { c } else { nil } }

    /// The toolbar note: a newer build, not dismissed with Later, and never while recording.
    var noteVisible: Bool { available != nil && !noteDismissed && recorder?.inSession != true }

    /// What the toolbar shows: "Updated to build N" (once, after an update) or "Update Didn't Install" take precedence.
    enum Note: Equatable { case updated(Int), failed(Int), available(UpdateCandidate) }
    var note: Note? {
        if let failedBuild, !noteDismissed { return .failed(failedBuild) }
        if noteVisible, let available { return .available(available) }   // a newer build matters more than "Updated"
        if updatedFrom != nil { return .updated(running.build) }
        return nil
    }

    func launchCheck() {
        // After a failed update, keep its message for the dialog rather than replacing it with a fresh check.
        guard UpdateSettings.checkAtLaunch(), UpdateSettings.source() != .off, failedBuild == nil else { return }
        check(userInitiated: false)
    }

    /// Starts a check unless one is running. A launch check that fails leaves the phase idle: nothing to show.
    /// The check in flight reports its failure (rather than staying quiet) once the user asks too.
    private var reportFailure = false

    func check(userInitiated: Bool) {
        // An install in progress owns the dialog; a new check would hide its progress and Cancel.
        guard installPhase == .idle || { if case .failed = installPhase { true } else { false } }() else { return }
        if userInitiated { reportFailure = true }
        guard checkTask == nil else {
            if userInitiated { phase = .checking }   // the launch check in flight now answers the user
            return
        }
        reportFailure = userInitiated
        if userInitiated || available == nil { phase = .checking }
        checkTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.fetch()
            self.checkTask = nil
            self.lastChecked = Date()
            switch result {
            case .success(let c?): self.phase = .available(c)
            case .success(nil): self.phase = .upToDate
            case .failure(let e): self.phase = self.reportFailure ? .failed(e.message) : (self.available.map(Phase.available) ?? .idle)
            }
        }
    }

    func later() { noteDismissed = true; failedBuild = nil }


    private func fetch() async -> Result<UpdateCandidate?, UpdateCheckError> {
        let source: any UpdateSource
        switch makeSource() {
        case .success(nil): return .success(nil)   // updates are off
        case .success(let s?): source = s
        case .failure(let e): return .failure(e)
        }
        let includeDebug = UpdateSettings.includeDebug()
        do {
            let found = try await source.candidates(above: running.build, includeDebug: includeDebug)
            return .success(UpdateCatalog.newest(found, running: running, bundleID: Bundle.main.bundleIdentifier ?? "",
                                                 teamID: teamID, includeDebug: includeDebug,
                                                 systemVersion: ProcessInfo.processInfo.operatingSystemVersion))
        } catch { return .failure(error) }
    }

    func makeSource() -> Result<(any UpdateSource)?, UpdateCheckError> {
        if let sourceOverride { return .success(sourceOverride) }
        switch UpdateSettings.source() {
        case .off: return .success(nil)
        case .github: return .success(GitHubReleasesSource())
        case .folder:
            guard let folder = Self.chosenFolder() else { return .failure(.noFolderChosen) }
            return .success(LocalFolderSource(folder: folder))
        }
    }

    /// Settings → Updates → Local folder, stored as a bookmark so a moved or renamed folder is still found.
    static func chosenFolder(_ d: UserDefaults = .standard) -> URL? {
        guard let data = d.data(forKey: UpdateSettings.folderBookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale, let fresh = try? url.bookmarkData() { d.set(fresh, forKey: UpdateSettings.folderBookmarkKey) }
        return url
    }

    static func choose(folder url: URL, _ d: UserDefaults = .standard) {
        guard let data = try? url.bookmarkData() else { return }
        d.set(data, forKey: UpdateSettings.folderBookmarkKey)
        d.set(url.path, forKey: UpdateSettings.folderPathKey)
    }
}
