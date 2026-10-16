import CryptoKit
import Foundation
import Testing
@testable import Models
import Domain

@Suite("Pack repair and HTTP resume", .serialized)
struct RepairAndHTTPTests {
    let base = ModelPackTests()

    @Test func reinstallingSameVersionRepairsCorruptPack() async throws {
        let f = try base.makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await base.installer(f).install(f.pack, from: DirectoryModelSource(root: f.sourceDir))
        let file = f.store.packDirectory("test-pack", "1.0.0").appending(path: "notes.test/model.gguf")
        let original = try Data(contentsOf: file)
        var d = original; d[5] ^= 0x01; try d.write(to: file)
        #expect(LocalModelRegistry(store: f.store, verification: .fullHash).state() == .corrupt(ModelManifestID("notes.test"), path: "model.gguf"))
        // The UI's "reinstall / import" action: same pack, same version.
        try await base.installer(f).install(f.pack, from: DirectoryModelSource(root: f.sourceDir))
        #expect(LocalModelRegistry(store: f.store, verification: .fullHash).state() == .ready(packID: "test-pack", version: "1.0.0"))
        #expect(try Data(contentsOf: file) == original, "damaged bytes replaced")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: f.store.stagingDirectory.path))?.isEmpty ?? true)
    }

    @Test func intactReinstallActivatesWithoutRefetching() async throws {
        let f = try base.makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await base.installer(f).install(f.pack, from: DirectoryModelSource(root: f.sourceDir))
        struct NoFetch: ModelSource {
            func fetch(_ file: ModelFile, manifest: ModelManifest, appendingTo partial: URL, from offset: Int64,
                       progress: @Sendable (Int64) -> Void, cancellation: CancellationToken) async throws {
                Issue.record("must not fetch when the installed copy verifies")
            }
        }
        try await base.installer(f).install(f.pack, from: NoFetch())
        #expect(f.store.activePack() == .init(packID: "test-pack", version: "1.0.0"))
    }

    @Test func damagedPackInUseIsNotModified() async throws {
        let f = try base.makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await base.installer(f).install(f.pack, from: DirectoryModelSource(root: f.sourceDir))
        let lease = try f.store.acquireLease(.init(packID: "test-pack", version: "1.0.0"))
        defer { f.store.releaseLease(lease) }
        let file = f.store.packDirectory("test-pack", "1.0.0").appending(path: "asr.test/vocab.json")
        try Data("xxxxxxx".utf8).write(to: file) // same size, different bytes
        await #expect(throws: ModelInstallError.packInUse("damaged pack is in use by a running job; retry when it finishes")) {
            try await base.installer(f).install(f.pack, from: DirectoryModelSource(root: f.sourceDir))
        }
    }

    // MARK: HTTP

    /// Serves fixture bytes for https://mock.amaranth/<manifest>/<path>; honours Range only when `honourRange` is set.
    final class MockServer: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var files: [String: Data] = [:]
        nonisolated(unsafe) static var honourRange = true
        nonisolated(unsafe) static var failAfterBytes: Int? = nil
        override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "mock.amaranth" }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let url = request.url, let data = Self.files[url.path] else {
                client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist)); return
            }
            var body = data, status = 200
            if Self.honourRange, let r = request.value(forHTTPHeaderField: "Range"), r.hasPrefix("bytes="),
               let start = Int(r.dropFirst(6).dropLast()) {
                body = data.subdata(in: start..<data.count); status = 206
            }
            let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "\(body.count)"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            if let limit = Self.failAfterBytes {
                client?.urlProtocol(self, didLoad: body.prefix(limit))
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                return
            }
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    func httpFixture() throws -> (ModelPackTests.Fixture, ModelPack, HTTPModelSource) {
        let f = try base.makeFixture()
        var pack = f.pack
        MockServer.files = [:]
        for (mi, m) in pack.manifests.enumerated() {
            for (fi, file) in m.files.enumerated() {
                let path = "/\(m.id.rawValue)/\(file.path)"
                MockServer.files[path] = try Data(contentsOf: f.sourceDir.appending(path: m.id.rawValue).appending(path: file.path))
                pack.manifests[mi].files[fi].sourceURL = URL(string: "https://mock.amaranth\(path)")
            }
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockServer.self]
        return (f, pack, HTTPModelSource(session: URLSession(configuration: config)))
    }

    @Test func httpInterruptedDownloadResumesWithRange() async throws {
        let (f, pack, source) = try httpFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        MockServer.honourRange = true
        MockServer.failAfterBytes = 50_000
        await #expect(throws: (any Error).self) { try await base.installer(f).install(pack, from: source) }
        #expect(f.store.activePack() == nil)
        MockServer.failAfterBytes = nil
        try await base.installer(f).install(pack, from: source)
        #expect(LocalModelRegistry(store: f.store, verification: .fullHash).state() == .ready(packID: "test-pack", version: "1.0.0"))
    }

    @Test func httpServerIgnoringRangeRestartsFileCleanly() async throws {
        let (f, pack, source) = try httpFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        MockServer.honourRange = false
        MockServer.failAfterBytes = 50_000
        await #expect(throws: (any Error).self) { try await base.installer(f).install(pack, from: source) }
        MockServer.failAfterBytes = nil
        // The retry gets HTTP 200 for a Range request: the partial must be truncated, not appended to.
        try await base.installer(f).install(pack, from: source)
        #expect(LocalModelRegistry(store: f.store, verification: .fullHash).state() == .ready(packID: "test-pack", version: "1.0.0"))
        MockServer.honourRange = true
    }
}
