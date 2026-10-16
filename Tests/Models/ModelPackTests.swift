import CryptoKit
import Foundation
import Testing
@testable import Models
import Domain

@Suite("Model pack install and registry", .serialized)
struct ModelPackTests {
    struct Fixture {
        let root: URL
        let sourceDir: URL
        let store: ModelPackStore
        let pack: ModelPack
    }

    static func hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    /// Two manifests, three files (one nested like an .mlmodelc bundle), written into a directory source.
    func makeFixture(revision: String = String(repeating: "a", count: 40), minimumOS: String = "26.5.2") throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "amr-models-\(UUID())")
        let src = root.appending(path: "source")
        let files: [(String, String, Data)] = [
            ("asr.test", "Encoder.mlmodelc/weights/weight.bin", Data((0..<300_000).map { UInt8($0 % 251) })),
            ("asr.test", "vocab.json", Data(#"{"a":1}"#.utf8)),
            ("notes.test", "model.gguf", Data((0..<120_000).map { UInt8(($0 * 7) % 256) })),
        ]
        var byManifest: [String: [ModelFile]] = [:]
        for (m, path, data) in files {
            let url = src.appending(path: m).appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            byManifest[m, default: []].append(ModelFile(path: path, sha256: Self.hex(data), byteSize: Int64(data.count)))
        }
        let manifests = byManifest.keys.sorted().map { id in
            ModelManifest(id: ModelManifestID(id), version: "1", role: id.hasPrefix("asr") ? .asr : .summary, family: "test",
                          sourceRepository: "example/\(id)", sourceRevision: revision, conversionProvenance: "test fixture",
                          files: byManifest[id]!, license: ModelLicense(identifier: "MIT", attribution: "test"), minimumOS: minimumOS)
        }
        return Fixture(root: root, sourceDir: src, store: ModelPackStore(root: root.appending(path: "store")),
                       pack: ModelPack(id: "test-pack", version: "1.0.0", profile: .standard16GB, manifests: manifests))
    }

    func installer(_ f: Fixture, margin: Int64 = 0) -> ModelInstaller { ModelInstaller(store: f.store, safetyMarginBytes: margin) }

    @Test func freshInstallVerifiesActivatesAndResolvesOffline() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let phases = PhaseLog()
        try await installer(f).install(f.pack, from: DirectoryModelSource(root: f.sourceDir)) { phases.add($0.phase) }
        #expect(f.store.activePack() == .init(packID: "test-pack", version: "1.0.0"))
        let reg = LocalModelRegistry(store: f.store, verification: .fullHash)
        #expect(reg.state() == .ready(packID: "test-pack", version: "1.0.0"))
        let asr = try reg.resolve(ModelManifestID("asr.test"))
        #expect(FileManager.default.fileExists(atPath: asr.url(for: "Encoder.mlmodelc/weights/weight.bin").path))
        #expect(phases.all.contains(.verifying) && phases.all.last == .done)
        // Staging is consumed by activation.
        #expect((try? FileManager.default.contentsOfDirectory(atPath: f.store.stagingDirectory.path))?.isEmpty ?? true)
    }

    /// Fails after delivering `limit` bytes of the first file it sees, simulating a dropped connection.
    struct FlakySource: ModelSource {
        let inner: DirectoryModelSource
        let limit: Int64
        func fetch(_ file: ModelFile, manifest: ModelManifest, appendingTo partial: URL, from offset: Int64,
                   progress: @Sendable (Int64) -> Void, cancellation: CancellationToken) async throws {
            let src = inner.root.appending(path: manifest.id.rawValue).appending(path: file.path)
            let data = try Data(contentsOf: src)
            let end = min(Int64(data.count), offset + limit)
            let h = try FileHandle(forWritingTo: partial)
            try h.seekToEnd()
            try h.write(contentsOf: data[Int(offset)..<Int(end)])
            try h.close()
            if end < Int64(data.count) { throw ModelInstallError.network("connection reset") }
        }
    }

    @Test func interruptedInstallNeverActivatesAndResumes() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await #expect(throws: ModelInstallError.network("connection reset")) {
            try await installer(f).install(f.pack, from: FlakySource(inner: DirectoryModelSource(root: f.sourceDir), limit: 100_000))
        }
        #expect(f.store.activePack() == nil, "partial files are never activated")
        #expect(LocalModelRegistry(store: f.store).state() == .notInstalled)
        // A partial exists with exactly the delivered bytes; the next attempt resumes from it.
        let partial = f.store.stagingDirectory.appending(path: "test-pack-1.0.0/asr.test/Encoder.mlmodelc/weights/weight.bin.partial")
        #expect((try FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int64) == 100_000)
        let fetched = ByteLog()
        struct CountingSource: ModelSource {
            let inner: DirectoryModelSource; let log: ByteLog
            func fetch(_ file: ModelFile, manifest: ModelManifest, appendingTo partial: URL, from offset: Int64,
                       progress: @Sendable (Int64) -> Void, cancellation: CancellationToken) async throws {
                log.add(file.byteSize - offset)
                try await inner.fetch(file, manifest: manifest, appendingTo: partial, from: offset, progress: progress, cancellation: cancellation)
            }
        }
        try await installer(f).install(f.pack, from: CountingSource(inner: DirectoryModelSource(root: f.sourceDir), log: fetched))
        let total = f.pack.manifests.reduce(0) { $0 + $1.totalBytes }
        #expect(fetched.total == total - 100_000, "resumed instead of restarting")
        #expect(LocalModelRegistry(store: f.store, verification: .fullHash).state() == .ready(packID: "test-pack", version: "1.0.0"))
    }

    @Test func corruptSourceIsRejectedAndDiscarded() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        // Flip a byte in the source after the manifest was hashed.
        let victim = f.sourceDir.appending(path: "notes.test/model.gguf")
        var d = try Data(contentsOf: victim); d[1000] ^= 0xff; try d.write(to: victim)
        await #expect(throws: ModelInstallError.self) {
            try await installer(f).install(f.pack, from: DirectoryModelSource(root: f.sourceDir))
        }
        #expect(f.store.activePack() == nil)
        let partial = f.store.stagingDirectory.appending(path: "test-pack-1.0.0/notes.test/model.gguf.partial")
        #expect(!FileManager.default.fileExists(atPath: partial.path), "corrupt bytes are discarded")
    }

    @Test func insufficientSpaceIsReportedBeforeDownloading() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let huge = ModelInstaller(store: f.store, safetyMarginBytes: Int64.max / 4)
        await #expect {
            try await huge.install(f.pack, from: DirectoryModelSource(root: f.sourceDir))
        } throws: { e in
            if case ModelInstallError.insufficientSpace = e { return true }
            return false
        }
        #expect(f.store.activePack() == nil)
    }

    @Test func floatingRevisionsUnsafePathsAndNewerOSAreRejected() async throws {
        let floating = try makeFixture(revision: "main")
        defer { try? FileManager.default.removeItem(at: floating.root) }
        await #expect(throws: ModelInstallError.self) { try await installer(floating).install(floating.pack, from: DirectoryModelSource(root: floating.sourceDir)) }

        let future = try makeFixture(minimumOS: "99.0")
        defer { try? FileManager.default.removeItem(at: future.root) }
        await #expect(throws: ModelInstallError.incompatible("asr.test requires macOS 99.0")) {
            try await installer(future).install(future.pack, from: DirectoryModelSource(root: future.sourceDir))
        }

        var evil = try makeFixture()
        defer { try? FileManager.default.removeItem(at: evil.root) }
        var m = evil.pack.manifests[0]
        m.files[0].path = "../../escape.bin"
        evil = Fixture(root: evil.root, sourceDir: evil.sourceDir, store: evil.store,
                       pack: ModelPack(id: "p", version: "1", profile: .standard16GB, manifests: [m]))
        await #expect(throws: ModelInstallError.self) { try await installer(evil).install(evil.pack, from: DirectoryModelSource(root: evil.sourceDir)) }
    }

    @Test func corruptionAfterInstallIsReportedWithoutRepair() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await installer(f).install(f.pack, from: DirectoryModelSource(root: f.sourceDir))
        let file = f.store.packDirectory("test-pack", "1.0.0").appending(path: "notes.test/model.gguf")
        // Same size, different bytes: only the full-hash check catches it.
        var d = try Data(contentsOf: file); d[5] ^= 0x01; try d.write(to: file)
        #expect(LocalModelRegistry(store: f.store, verification: .sizes).state() == .ready(packID: "test-pack", version: "1.0.0"))
        #expect(LocalModelRegistry(store: f.store, verification: .fullHash).state() == .corrupt(ModelManifestID("notes.test"), path: "model.gguf"))
        // Truncation is caught by the fast check.
        try d.prefix(10).write(to: file)
        #expect(throws: ModelRegistryError.corrupt(ModelManifestID("notes.test"), path: "model.gguf")) {
            _ = try LocalModelRegistry(store: f.store).resolve(ModelManifestID("notes.test"))
        }
        // The other model stays usable (record-only and ASR remain available).
        #expect(throws: Never.self) { _ = try LocalModelRegistry(store: f.store).resolve(ModelManifestID("asr.test")) }
    }

    @Test func leasedPackCannotBeRemovedAndUpgradeKeepsOldVersionWhileInUse() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await installer(f).install(f.pack, from: DirectoryModelSource(root: f.sourceDir))
        let v1 = ModelPackStore.ActivePack(packID: "test-pack", version: "1.0.0")
        let lease = try f.store.acquireLease(v1)
        // Install v2 (same files) — v1 must remain on disk while leased.
        var p2 = f.pack; p2.version = "2.0.0"
        try await installer(f).install(p2, from: DirectoryModelSource(root: f.sourceDir))
        #expect(f.store.activePack()?.version == "2.0.0")
        #expect(throws: ModelInstallError.packInUse("leased by a running job")) { try f.store.remove(v1) }
        #expect(FileManager.default.fileExists(atPath: f.store.packDirectory("test-pack", "1.0.0").path))
        f.store.releaseLease(lease)
        try f.store.remove(v1)
        #expect(!FileManager.default.fileExists(atPath: f.store.packDirectory("test-pack", "1.0.0").path))
        #expect(throws: ModelInstallError.packInUse("active")) { try f.store.remove(.init(packID: "test-pack", version: "2.0.0")) }
    }

    @Test func cancellationLeavesNothingActive() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let token = CancellationToken()
        token.cancel()
        await #expect(throws: CancellationError.self) {
            try await installer(f).install(f.pack, from: DirectoryModelSource(root: f.sourceDir), cancellation: token)
        }
        #expect(f.store.activePack() == nil)
    }

    @Test func registryHasNoNetworkCode() throws {
        // Guard against regressions: inference-side resolution must not reference URLSession or remote URLs.
        let src = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Models/LocalModelRegistry.swift")
        let text = try String(contentsOf: src, encoding: .utf8)
        #expect(!text.contains("URLSession") && !text.contains("http"))
    }
}

final class PhaseLog: @unchecked Sendable {
    private let lock = NSLock(); private var phases: [InstallProgress.Phase] = []
    func add(_ p: InstallProgress.Phase) { lock.withLock { if phases.last != p { phases.append(p) } } }
    var all: [InstallProgress.Phase] { lock.withLock { phases } }
}

final class ByteLog: @unchecked Sendable {
    private let lock = NSLock(); private var n: Int64 = 0
    func add(_ v: Int64) { lock.withLock { n += v } }
    var total: Int64 { lock.withLock { n } }
}
