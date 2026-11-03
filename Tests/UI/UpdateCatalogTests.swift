import Foundation
import Testing
@testable import Presentation

private let team = "WLKNK4P84Z", bundle = "com.alexmartin.amaranth"
private let macOS = OperatingSystemVersion(majorVersion: 26, minorVersion: 5, patchVersion: 2)

private func manifest(_ build: Int, _ channel: String = "release", team t: String = team, bundleID: String = bundle,
                      minOS: String = "26.5.2", sha: String = String(repeating: "a", count: 64), asset: String? = nil,
                      format: Int = 1, size: Int64 = 1000) -> UpdateManifest {
    UpdateManifest(format: format, bundleID: bundleID, version: "0.1.0", build: build, commit: "c\(build)", channel: channel,
                   asset: asset ?? "Amaranth-0.1.0-\(build)\(channel == "debug" ? "-debug" : "").zip", size: size, sha256: sha, teamID: t,
                   minimumSystemVersion: minOS, schemaVersion: 6)
}

private func candidate(_ m: UpdateManifest) -> UpdateCandidate {
    UpdateCandidate(manifest: m, download: URL(string: "https://example.invalid/\(m.asset)")!)
}

private func pick(_ ms: [UpdateManifest], running: Int = 120, runningChannel: BuildInfo.Channel = .release, debug: Bool = false,
                  teamID: String? = team) -> (build: Int, channel: String)? {
    let running = BuildInfo(version: "0.1.0", build: running, commit: "x", channel: runningChannel)
    return UpdateCatalog.newest(ms.map(candidate), running: running, bundleID: bundle, teamID: teamID, includeDebug: debug, systemVersion: macOS)
        .map { ($0.manifest.build, $0.manifest.channel) }
}

@Suite("Update catalog (T71)")
struct UpdateCatalogTests {
    @Test func picksTheNewestReleaseAboveTheRunningBuild() {
        #expect(pick([manifest(121), manifest(125), manifest(123)])! == (125, "release"))
    }

    @Test func neverTheSameOrAnOlderBuild() {
        #expect(pick([manifest(120), manifest(119), manifest(3)]) == nil)
        #expect(pick([]) == nil)
    }

    @Test func debugBuildsOnlyWithTheOptIn() {
        let ms = [manifest(122), manifest(126, "debug")]
        #expect(pick(ms)! == (122, "release"))
        #expect(pick(ms, debug: true)! == (126, "debug"))
        #expect(pick([manifest(126, "debug")]) == nil)
    }

    @Test func aReleaseBeatsADebugBuildOfTheSameNumber() {
        #expect(pick([manifest(124, "debug"), manifest(124)], debug: true)! == (124, "release"))
        #expect(pick([manifest(124), manifest(124, "debug")], debug: true)! == (124, "release"))
    }

    @Test func aDebugBuildIsOfferedAReleaseOnlyWhenNewer() {
        #expect(pick([manifest(120)], running: 120, runningChannel: .debug) == nil)
        #expect(pick([manifest(121)], running: 120, runningChannel: .debug)! == (121, "release"))
    }

    @Test func otherTeamsAndOtherAppsAreSkipped() {
        #expect(pick([manifest(130, team: "ZZZZZZZZZZ"), manifest(122)])! == (122, "release"))
        #expect(pick([manifest(130, bundleID: "com.example.other")]) == nil)
        #expect(pick([manifest(122)], teamID: nil) == nil, "an ad-hoc running app can't check a team, so nothing is offered")
        #expect(pick([manifest(122)], teamID: "") == nil)
    }

    @Test func malformedManifestsAreSkipped() {
        let bad = [
            manifest(130, sha: "not-a-sha"), manifest(131, sha: String(repeating: "g", count: 64)), manifest(132, asset: "../evil.zip"),
            manifest(133, asset: "Amaranth.dmg"), manifest(134, format: 2), manifest(135, size: 0), manifest(136, "nightly"),
            manifest(137, minOS: "twenty-six"), manifest(138, asset: ""),
        ]
        #expect(pick(bad + [manifest(122)])! == (122, "release"))
        #expect(pick(bad) == nil)
    }

    @Test func aBuildForANewerMacOSIsSkipped() {
        #expect(pick([manifest(140, minOS: "27.0"), manifest(122, minOS: "26.5")])! == (122, "release"))
        #expect(pick([manifest(140, minOS: "26.5.3")]) == nil)
        #expect(pick([manifest(140, minOS: "26")])! == (140, "release"))
    }

    @Test func manifestsRoundTripThroughJSON() throws {
        let m = manifest(124)
        #expect(UpdateManifest.decode(try JSONEncoder().encode(m)) == m)
        #expect(UpdateManifest.decode(Data("{\"build\": 3}".utf8)) == nil)
        #expect(UpdateManifest.decode(Data("<html>".utf8)) == nil)
    }
}

// MARK: - GitHub Releases, against recorded API responses (no network)

/// Answers requests from a table keyed by URL; anything else is a 404. Records what was asked.
private final class FakeGitHub: @unchecked Sendable {
    var routes: [String: (Int, [String: String], Data)] = [:]
    var error: URLError?
    private(set) var requested: [String] = []
    private let lock = NSLock()

    func fetch(_ r: URLRequest) async throws -> (Data, URLResponse) {
        let url = r.url!.absoluteString
        lock.withLock { requested.append(url) }
        if let error { throw error }
        let (status, headers, data) = routes[url] ?? (404, [:], Data("Not Found".utf8))
        return (data, HTTPURLResponse(url: r.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }

    var source: GitHubReleasesSource { GitHubReleasesSource(fetch: { try await self.fetch($0) }) }
}

private let releasesURL = "https://api.github.com/repos/ATMartin/amaranth/releases?per_page=50"
private func dl(_ tag: String, _ name: String) -> String { "https://github.com/ATMartin/amaranth/releases/download/\(tag)/\(name)" }

/// Shaped like the API's answer (trimmed to the fields read; recorded from ATMartin/amaranth, 2026-11-02).
private func releaseJSON(_ tag: String, draft: Bool = false, prerelease: Bool = false, assets: [(String, String)]) -> String {
    let a = assets.map { name, state in
        """
        {"url":"https://api.github.com/repos/ATMartin/amaranth/releases/assets/1","name":"\(name)","label":"","state":"\(state)",\
        "content_type":"application/zip","size":1000,"browser_download_url":"\(dl(tag, name))"}
        """
    }
    return """
    {"url":"https://api.github.com/repos/ATMartin/amaranth/releases/1","html_url":"https://github.com/ATMartin/amaranth/releases/tag/\(tag)",\
    "tag_name":"\(tag)","target_commitish":"main","name":"Amaranth","draft":\(draft),"prerelease":\(prerelease),\
    "created_at":"2026-11-02T22:00:00Z","published_at":"2026-11-02T22:01:00Z","assets":[\(a.joined(separator: ","))],"body":"Build"}
    """
}

private func zipName(_ build: Int, _ debug: Bool = false) -> String { "Amaranth-0.1.0-\(build)\(debug ? "-debug" : "").zip" }
private func json(_ m: UpdateManifest) -> Data { try! JSONEncoder().encode(m) }

@Suite("GitHub Releases source (T71)")
struct GitHubReleasesSourceTests {
    @Test func readsManifestsOfNewerReleasesNewestFirstAndSkipsOlderOnes() async throws {
        let gh = FakeGitHub()
        let list = [
            releaseJSON("build-124", assets: [(zipName(124), "uploaded"), ("manifest.json", "uploaded")]),
            releaseJSON("build-123-debug", prerelease: true, assets: [(zipName(123, true), "uploaded"), ("manifest.json", "uploaded")]),
            releaseJSON("build-119", assets: [(zipName(119), "uploaded"), ("manifest.json", "uploaded")]),
        ]
        gh.routes[releasesURL] = (200, ["x-ratelimit-remaining": "58"], Data("[\(list.joined(separator: ","))]".utf8))
        gh.routes[dl("build-124", "manifest.json")] = (200, [:], json(manifest(124)))
        gh.routes[dl("build-123-debug", "manifest.json")] = (200, [:], json(manifest(123, "debug")))
        let found = try await gh.source.candidates(above: 120, includeDebug: false)
        #expect(found.map(\.manifest.build) == [124])
        #expect(found.first?.download.absoluteString == dl("build-124", zipName(124)))
        #expect(found.first?.page?.absoluteString == "https://github.com/ATMartin/amaranth/releases/tag/build-124")
        #expect(!gh.requested.contains(dl("build-119", "manifest.json")), "older builds' manifests aren't fetched")
        #expect(!gh.requested.contains(dl("build-123-debug", "manifest.json")), "debug manifests only with the opt-in")
        let withDebug = try await gh.source.candidates(above: 120, includeDebug: true)
        #expect(withDebug.map(\.manifest.build) == [124, 123])
    }

    @Test func aReleaseWithoutItsManifestOrStillUploadingIsNeverOffered() async throws {
        let gh = FakeGitHub()
        let list = [
            releaseJSON("build-126", assets: [(zipName(126), "uploaded")]),                                  // manifest not up yet
            releaseJSON("build-125", assets: [(zipName(125), "uploaded"), ("manifest.json", "starter")]),     // still uploading
            releaseJSON("build-124", draft: true, assets: [(zipName(124), "uploaded"), ("manifest.json", "uploaded")]),
            releaseJSON("build-123", assets: [("manifest.json", "uploaded")]),                                // zip missing
            releaseJSON("v1.0", assets: [("manifest.json", "uploaded")]),                                     // not ours
            releaseJSON("build-122", assets: [(zipName(122), "uploaded"), ("manifest.json", "uploaded")]),
        ]
        gh.routes[releasesURL] = (200, [:], Data("[\(list.joined(separator: ","))]".utf8))
        gh.routes[dl("build-123", "manifest.json")] = (200, [:], json(manifest(123)))
        gh.routes[dl("build-122", "manifest.json")] = (200, [:], json(manifest(122)))
        let found = try await gh.source.candidates(above: 120, includeDebug: true)
        #expect(found.map(\.manifest.build) == [122])
    }

    @Test func badManifestsAreSkippedAndTheNextOneIsRead() async throws {
        let gh = FakeGitHub()
        let list = (121...124).reversed().map { releaseJSON("build-\($0)", assets: [(zipName($0), "uploaded"), ("manifest.json", "uploaded")]) }
        gh.routes[releasesURL] = (200, [:], Data("[\(list.joined(separator: ","))]".utf8))
        gh.routes[dl("build-124", "manifest.json")] = (200, [:], Data("{ not json".utf8))
        gh.routes[dl("build-123", "manifest.json")] = (200, [:], json(manifest(999)))                // build differs from the tag
        gh.routes[dl("build-122", "manifest.json")] = (500, [:], Data())
        gh.routes[dl("build-121", "manifest.json")] = (200, [:], json(manifest(121)))
        #expect(try await gh.source.candidates(above: 120, includeDebug: false).map(\.manifest.build) == [121])
    }

    @Test func errorsArePlainAndNotRetried() async {
        let gh = FakeGitHub()
        gh.error = URLError(.notConnectedToInternet)
        await #expect(throws: UpdateCheckError.offline) { try await gh.source.candidates(above: 1, includeDebug: false) }
        gh.error = URLError(.timedOut)
        await #expect(throws: UpdateCheckError.timedOut) { try await gh.source.candidates(above: 1, includeDebug: false) }
        #expect(gh.requested.count == 2, "one request per check, no retries")
        gh.error = nil
        gh.routes[releasesURL] = (403, ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1793750400"], Data("{\"message\":\"API rate limit exceeded\"}".utf8))
        await #expect(throws: UpdateCheckError.rateLimited(until: Date(timeIntervalSince1970: 1793750400))) {
            try await gh.source.candidates(above: 1, includeDebug: false)
        }
        gh.routes[releasesURL] = (403, [:], Data())
        await #expect(throws: UpdateCheckError.server(status: 403)) { try await gh.source.candidates(above: 1, includeDebug: false) }
        gh.routes[releasesURL] = (502, [:], Data())
        await #expect(throws: UpdateCheckError.server(status: 502)) { try await gh.source.candidates(above: 1, includeDebug: false) }
        gh.error = URLError(.secureConnectionFailed)
        await #expect(throws: UpdateCheckError.unreachable(code: URLError.secureConnectionFailed.rawValue)) {
            try await gh.source.candidates(above: 1, includeDebug: false)
        }
        gh.error = nil
        gh.routes[releasesURL] = (200, [:], Data("<html>".utf8))
        await #expect(throws: UpdateCheckError.unreadable) { try await gh.source.candidates(above: 1, includeDebug: false) }
        #expect(UpdateCheckError.offline.message.contains("offline"))
    }

    @Test func aNetworkFailureOnAManifestIsAnErrorNotUpToDate() async {
        let gh = FakeGitHub()
        gh.routes[releasesURL] = (200, [:], Data("[\(releaseJSON("build-124", assets: [(zipName(124), "uploaded"), ("manifest.json", "uploaded")]))]".utf8))
        let source = GitHubReleasesSource(fetch: { r in
            if r.url!.absoluteString.hasSuffix("manifest.json") { throw URLError(.notConnectedToInternet) }
            return try await gh.fetch(r)
        })
        await #expect(throws: UpdateCheckError.offline) { try await source.candidates(above: 120, includeDebug: false) }
    }

    @Test func parsesTags() {
        #expect(GitHubReleasesSource.parseTag("build-124")! == (124, .release))
        #expect(GitHubReleasesSource.parseTag("build-124-debug")! == (124, .debug))
        for bad in ["build-", "build-x", "build-12-beta", "v124", "build-0", "build-124-debug-2"] { #expect(GitHubReleasesSource.parseTag(bad) == nil) }
    }
}

@Suite("Local folder source (T71)")
struct LocalFolderSourceTests {
    @Test func readsThePublishLayoutAndSkipsIncompleteFolders() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "amaranth-updates-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        func put(_ channel: String, _ dir: String, manifest m: UpdateManifest?, zip: Bool = true) throws {
            let d = root.appending(path: "\(channel)/\(dir)")
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            if let m { try json(m).write(to: d.appending(path: "manifest.json")) }
            if zip, let m { try Data("zip".utf8).write(to: d.appending(path: m.asset)) }
        }
        try put("release", "124", manifest: manifest(124))
        try put("release", "125", manifest: nil)                              // no manifest
        try put("release", "126", manifest: manifest(126), zip: false)       // no zip
        try put("release", ".staging-127", manifest: manifest(127))          // publish.sh staging
        try put("release", "119", manifest: manifest(119))                   // older
        try put("debug", "125", manifest: manifest(125, "debug"))
        try put("debug", "128", manifest: manifest(128))                     // wrong channel for its folder
        let source = LocalFolderSource(folder: root)
        #expect(try await source.candidates(above: 120, includeDebug: false).map(\.manifest.build) == [124])
        #expect(try await source.candidates(above: 120, includeDebug: true).map(\.manifest.build).sorted() == [124, 125])
        let missing = LocalFolderSource(folder: root.appending(path: "nope"))
        await #expect(throws: UpdateCheckError.folderMissing(root.appending(path: "nope").path)) {
            try await missing.candidates(above: 1, includeDebug: false)
        }
    }
}

@Suite("GitHub Releases source, recorded responses (T71)")
struct GitHubRecordedResponseTests {
    static let fixtures = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")

    /// The API's real answer and build-122's real manifest, recorded 2026-11-02 after the first publish.
    @Test func theFirstPublishedBuildIsOffered() async throws {
        let gh = FakeGitHub()
        gh.routes[releasesURL] = (200, ["x-ratelimit-remaining": "59"], try Data(contentsOf: Self.fixtures.appending(path: "github-releases-2026-11-02.json")))
        gh.routes[dl("build-122", "manifest.json")] = (200, [:], try Data(contentsOf: Self.fixtures.appending(path: "manifest-build-122.json")))
        let found = try await gh.source.candidates(above: 1, includeDebug: false)
        #expect(found.map(\.manifest.build) == [122])
        let running = BuildInfo(version: "0.1.0", build: 1, commit: "bc3d6a4", channel: .release)
        let pick = UpdateCatalog.newest(found, running: running, bundleID: bundle, teamID: team, includeDebug: false, systemVersion: macOS)
        #expect(pick?.manifest.asset == "Amaranth-0.1.0-122.zip" && pick?.download.absoluteString == dl("build-122", "Amaranth-0.1.0-122.zip"))
        #expect(try await gh.source.candidates(above: 122, includeDebug: true).isEmpty)
    }
}

@Suite("Install-time checks (T72)")
struct UpdateBundleCheckTests {
    static let good = UpdateBundleFacts(signatureValid: true, bundleID: bundle, teamID: team, build: 124, channel: "release",
                                        minimumSystemVersion: "26.5.2", architectures: ["arm64"])

    func problems(_ f: UpdateBundleFacts, runningTeam: String? = team) -> [String] {
        UpdateBundleCheck.problems(f, manifest: manifest(124), runningBundleID: bundle, runningTeamID: runningTeam, systemVersion: macOS)
    }

    @Test func aMatchingBuildPasses() { #expect(problems(Self.good).isEmpty) }

    @Test func eachMismatchIsNamed() {
        var f = Self.good; f.signatureValid = false
        #expect(problems(f).first?.contains("signature") == true)
        f = Self.good; f.teamID = "ZZZZZZZZZZ"
        #expect(problems(f).first?.contains("team ZZZZZZZZZZ") == true)
        f = Self.good; f.teamID = nil
        #expect(problems(f).first?.contains("no team") == true)
        #expect(!problems(Self.good, runningTeam: nil).isEmpty, "an ad-hoc running app accepts nothing")
        f = Self.good; f.bundleID = "com.example.other"
        #expect(problems(f).first?.contains("different app") == true)
        f = Self.good; f.architectures = ["x86_64"]
        #expect(problems(f).first?.contains("Apple silicon") == true)
        f = Self.good; f.minimumSystemVersion = "27.0"
        #expect(problems(f).first?.contains("macOS 27.0") == true)
        f = Self.good; f.minimumSystemVersion = nil
        #expect(!problems(f).isEmpty)
        f = Self.good; f.build = 123
        #expect(problems(f).first?.contains("build 123") == true)
        f = Self.good; f.channel = "debug"
        #expect(problems(f).first?.contains("debug build") == true)
    }

    @Test func sha256OfAFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "digest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        #expect(try FileDigest.sha256(of: url) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
