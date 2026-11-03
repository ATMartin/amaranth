public import Foundation

// Milestone Q (T71): what Check for Updates… offers. Builds are published by scripts/publish.sh as a zipped app plus a
// manifest.json, either as GitHub releases on ATMartin/amaranth (tag build-<N>, or build-<N>-debug as a prerelease) or in
// a local folder (<folder>/<channel>/<N>/). A release without its manifest is never offered.

/// manifest.json, as scripts/publish.sh writes it.
public struct UpdateManifest: Codable, Equatable, Sendable {
    public var format: Int
    public var app: String
    public var bundleID: String
    public var version: String
    public var build: Int
    public var commit: String
    public var commitSha: String
    public var channel: String
    public var date: String
    /// The zip's file name (the GitHub asset name, or the file beside the manifest).
    public var asset: String
    public var size: Int64
    public var sha256: String
    public var teamID: String
    public var minimumSystemVersion: String
    public var schemaVersion: Int
    /// Commit subjects since the previous published build of the channel, newest first.
    public var changes: [String]

    public init(format: Int = 1, app: String = "Amaranth", bundleID: String, version: String, build: Int, commit: String, commitSha: String = "",
                channel: String, date: String = "", asset: String, size: Int64, sha256: String, teamID: String,
                minimumSystemVersion: String, schemaVersion: Int, changes: [String] = []) {
        self.format = format; self.app = app; self.bundleID = bundleID; self.version = version; self.build = build; self.commit = commit
        self.commitSha = commitSha; self.channel = channel; self.date = date; self.asset = asset; self.size = size; self.sha256 = sha256
        self.teamID = teamID; self.minimumSystemVersion = minimumSystemVersion; self.schemaVersion = schemaVersion; self.changes = changes
    }

    public var buildChannel: BuildInfo.Channel? { BuildInfo.Channel(rawValue: channel) }
    /// "0.1.0 (124)", with " Debug" for the debug channel.
    public var label: String { "\(version) (\(build))" + (buildChannel == .debug ? " Debug" : "") }

    public static func decode(_ data: Data) -> UpdateManifest? { try? JSONDecoder().decode(UpdateManifest.self, from: data) }
}

/// A published build: its manifest and where its zip is.
public struct UpdateCandidate: Equatable, Sendable {
    public var manifest: UpdateManifest
    public var download: URL
    /// The release page (GitHub) or folder, for "More…".
    public var page: URL?

    public init(manifest: UpdateManifest, download: URL, page: URL? = nil) {
        self.manifest = manifest; self.download = download; self.page = page
    }
}

/// Picks the build to offer. Pure, so the rules are table-tested.
public enum UpdateCatalog {
    public static let supportedFormat = 1

    /// The newest acceptable build above the running one, or nil. Release only unless `includeDebug`; at the same build
    /// number a release beats a debug build; never the running build or an older one (no rollbacks); never a manifest
    /// that is malformed, for another app or signed by another team (or when the running app has no team), or that needs
    /// a newer macOS than `systemVersion`.
    public static func newest(_ candidates: [UpdateCandidate], running: BuildInfo, bundleID: String, teamID: String?,
                              includeDebug: Bool, systemVersion: OperatingSystemVersion) -> UpdateCandidate? {
        guard let teamID, !teamID.isEmpty else { return nil }
        let eligible = candidates.filter { c in
            let m = c.manifest
            guard isWellFormed(m), m.bundleID == bundleID, m.teamID == teamID, m.build > running.build else { return false }
            guard let channel = m.buildChannel, channel == .release || includeDebug else { return false }
            guard let needs = parseVersion(m.minimumSystemVersion), !isNewer(needs, than: systemVersion) else { return false }
            return true
        }
        return eligible.max { a, b in
            if a.manifest.build != b.manifest.build { return a.manifest.build < b.manifest.build }
            return a.manifest.buildChannel == .debug && b.manifest.buildChannel == .release   // release wins a tie
        }
    }

    public static func isWellFormed(_ m: UpdateManifest) -> Bool {
        m.format == supportedFormat && m.build > 0 && m.size > 0 && !m.asset.isEmpty && !m.asset.contains("/")
            && m.asset.hasSuffix(".zip") && m.sha256.count == 64 && m.sha256.allSatisfy(\.isHexDigit) && m.buildChannel != nil
            && parseVersion(m.minimumSystemVersion) != nil
    }

    public static func parseVersion(_ s: String) -> OperatingSystemVersion? {
        let parts = s.split(separator: ".").map { Int($0) }
        guard (1...3).contains(parts.count), parts.allSatisfy({ $0 != nil }) else { return nil }
        let p = parts.map { $0! } + [0, 0]
        return OperatingSystemVersion(majorVersion: p[0], minorVersion: p[1], patchVersion: p[2])
    }

    static func isNewer(_ a: OperatingSystemVersion, than b: OperatingSystemVersion) -> Bool {
        (a.majorVersion, a.minorVersion, a.patchVersion) > (b.majorVersion, b.minorVersion, b.patchVersion)
    }
}

/// Why a check failed, in words for the dialog. Never retried on its own.
public enum UpdateCheckError: Error, Equatable, Sendable {
    case offline
    case timedOut
    case rateLimited(until: Date?)
    case server(status: Int)
    /// Any other transport failure (URLError code).
    case unreachable(code: Int)
    case unreadable
    case folderMissing(String)
    case noFolderChosen

    public var message: String {
        switch self {
        case .offline: "This Mac is offline. Check again when it's connected; nothing else in Amaranth needs the internet."
        case .timedOut: "GitHub didn't answer in time. Try again in a moment."
        case .rateLimited(let until):
            if let until { "GitHub has had too many checks from this network. Try again after \(until.formatted(date: .omitted, time: .shortened))." }
            else { "GitHub has had too many checks from this network. Try again in an hour." }
        case .server(let status): "GitHub answered with an error (HTTP \(status)). Try again later."
        case .unreachable(let code): "Couldn't reach GitHub (network error \(code)). Check the connection and try again."
        case .unreadable: "The list of builds couldn't be read. Try again later."
        case .folderMissing(let path): "The updates folder isn't available (\(path)). Choose it again in Settings → Updates."
        case .noFolderChosen: "Choose an updates folder in Settings → Updates."
        }
    }
}

/// Where published builds are listed.
public protocol UpdateSource: Sendable {
    /// Published builds above `build`, debug ones only when `includeDebug`. Malformed or missing manifests are left out.
    func candidates(above build: Int, includeDebug: Bool) async throws(UpdateCheckError) -> [UpdateCandidate]
}

/// GitHub Releases on a public repository, through the unauthenticated REST API (60 requests an hour per address): one
/// request for the release list; manifests are release downloads, which don't count against that limit.
public struct GitHubReleasesSource: UpdateSource {
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    public static let defaultRepository = "ATMartin/amaranth"
    /// Manifests read per check, newest first (enough to step past a broken or other-team release).
    public static let manifestLimit = 5

    public var repository: String
    var fetch: Fetch

    /// No cache: a cached release list would hide that the Mac is offline and could miss a new build.
    public static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 15
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    public init(repository: String = defaultRepository, fetch: @escaping Fetch = { try await GitHubReleasesSource.session.data(for: $0) }) {
        self.repository = repository; self.fetch = fetch
    }

    struct Release: Decodable {
        struct Asset: Decodable {
            var name: String
            var state: String?
            var browser_download_url: URL
        }
        var tag_name: String
        var draft: Bool?
        var html_url: URL?
        var assets: [Asset]
    }

    /// build-124 → (124, release); build-124-debug → (124, debug).
    static func parseTag(_ tag: String) -> (build: Int, channel: BuildInfo.Channel)? {
        let parts = tag.split(separator: "-")
        guard parts.first == "build", parts.count == 2 || (parts.count == 3 && parts[2] == "debug"), let n = Int(parts[1]), n > 0 else { return nil }
        return (n, parts.count == 3 ? .debug : .release)
    }

    public func candidates(above build: Int, includeDebug: Bool) async throws(UpdateCheckError) -> [UpdateCandidate] {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=50")!, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Amaranth-Updater", forHTTPHeaderField: "User-Agent")
        let data = try await get(request, api: true)
        guard let releases = try? JSONDecoder().decode([Release].self, from: data) else { throw .unreadable }
        let eligible = releases.compactMap { r -> (Release, Int, BuildInfo.Channel)? in
            guard r.draft != true, let (n, ch) = Self.parseTag(r.tag_name), n > build, ch == .release || includeDebug else { return nil }
            return (r, n, ch)
        }
        .sorted { ($0.1, $0.2 == .release ? 1 : 0) > ($1.1, $1.2 == .release ? 1 : 0) }
        var found: [UpdateCandidate] = []
        for (release, n, channel) in eligible.prefix(Self.manifestLimit) {
            let uploaded = release.assets.filter { $0.state == nil || $0.state == "uploaded" }
            guard let manifestAsset = uploaded.first(where: { $0.name == "manifest.json" }) else { continue }   // not finished publishing
            let manifestData: Data
            do { manifestData = try await get(URLRequest(url: manifestAsset.browser_download_url, timeoutInterval: 15), api: false) }
            catch .server { continue }   // a missing or broken asset: try the next release
            catch { throw error }        // the network: say so rather than "up to date"
            guard let m = UpdateManifest.decode(manifestData), m.build == n, m.buildChannel == channel,
                  let zip = uploaded.first(where: { $0.name == m.asset }) else { continue }
            found.append(UpdateCandidate(manifest: m, download: zip.browser_download_url, page: release.html_url))
        }
        return found
    }

    private func get(_ request: URLRequest, api: Bool) async throws(UpdateCheckError) -> Data {
        let data: Data, response: URLResponse
        do { (data, response) = try await fetch(request) } catch { throw Self.map(error) }
        guard let http = response as? HTTPURLResponse else { throw .unreadable }
        switch http.statusCode {
        case 200..<300: return data
        case 403 where api, 429 where api:
            if http.statusCode == 429 || http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" {
                let reset = http.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
                throw .rateLimited(until: reset)
            }
            throw .server(status: http.statusCode)
        default: throw .server(status: http.statusCode)
        }
    }

    public static func map(_ error: any Error) -> UpdateCheckError {
        // A blocked connection (a firewall, a sandbox) arrives as a POSIX error rather than a URLError.
        guard let e = error as? URLError else { return .unreachable(code: (error as NSError).code) }
        switch e.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed,
             .internationalRoamingOff:
            return .offline
        case .timedOut: return .timedOut
        default: return .unreachable(code: e.code.rawValue)
        }
    }
}

/// A folder laid out by `scripts/publish.sh --local-only`: <folder>/<release|debug>/<N>/{manifest.json, <asset>.zip}.
/// Folders without a manifest (or starting with a dot, like publish.sh's staging folder) are left out.
public struct LocalFolderSource: UpdateSource {
    public var folder: URL

    public init(folder: URL) { self.folder = folder }

    public func candidates(above build: Int, includeDebug: Bool) async throws(UpdateCheckError) -> [UpdateCandidate] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { throw .folderMissing(folder.path) }
        var found: [UpdateCandidate] = []
        for channel in BuildInfo.Channel.allCases where channel == .release || includeDebug {
            let dir = folder.appending(path: channel.rawValue)
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                guard !name.hasPrefix("."), let n = Int(name), n > build else { continue }
                let buildDir = dir.appending(path: name)
                guard let data = try? Data(contentsOf: buildDir.appending(path: "manifest.json")), let m = UpdateManifest.decode(data),
                      m.build == n, m.buildChannel == channel, !m.asset.contains("/") else { continue }
                let zip = buildDir.appending(path: m.asset)
                guard fm.fileExists(atPath: zip.path) else { continue }
                found.append(UpdateCandidate(manifest: m, download: zip, page: buildDir))
            }
        }
        return found
    }
}

/// Settings → Updates (T71), in UserDefaults.
public enum UpdateSettings {
    public enum Source: String, CaseIterable, Sendable { case github, folder, off }
    public static let sourceKey = "updates.source"
    public static let folderBookmarkKey = "updates.folderBookmark"
    public static let folderPathKey = "updates.folderPath"   // shown in Settings; the bookmark is what's used
    public static let includeDebugKey = "updates.includeDebug"
    public static let checkAtLaunchKey = "updates.checkAtLaunch"
    public static let sourceDefault = Source.github
    public static let includeDebugDefault = false
    public static let checkAtLaunchDefault = true

    public static func source(_ d: UserDefaults = .standard) -> Source { d.string(forKey: sourceKey).flatMap(Source.init) ?? sourceDefault }
    public static func includeDebug(_ d: UserDefaults = .standard) -> Bool { d.object(forKey: includeDebugKey) as? Bool ?? includeDebugDefault }
    public static func checkAtLaunch(_ d: UserDefaults = .standard) -> Bool { d.object(forKey: checkAtLaunchKey) as? Bool ?? checkAtLaunchDefault }
}
