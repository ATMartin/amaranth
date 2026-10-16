public import Foundation
public import Domain

/// Where model bytes come from during an **explicit** install. Inference never uses a source.
public protocol ModelSource: Sendable {
    /// Appends the bytes of `file` starting at `offset` to `partial` (resumable). Must honour cancellation.
    func fetch(_ file: ModelFile, manifest: ModelManifest, appendingTo partial: URL, from offset: Int64,
               progress: @Sendable (Int64) -> Void, cancellation: CancellationToken) async throws
}

/// Offline import of the same manifest + files from a directory laid out as `<manifestID>/<path>`.
public struct DirectoryModelSource: ModelSource {
    public let root: URL
    public init(root: URL) { self.root = root }

    public func fetch(_ file: ModelFile, manifest: ModelManifest, appendingTo partial: URL, from offset: Int64,
                      progress: @Sendable (Int64) -> Void, cancellation: CancellationToken) async throws {
        let src = root.appending(path: manifest.id.rawValue).appending(path: file.path)
        guard FileManager.default.fileExists(atPath: src.path) else { throw ModelInstallError.missingSource(path: file.path) }
        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }
        try input.seek(toOffset: UInt64(offset))
        let out = try FileHandle(forWritingTo: partial)
        defer { try? out.close() }
        try out.seekToEnd()
        while let chunk = try input.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            try cancellation.check()
            try out.write(contentsOf: chunk)
            progress(Int64(chunk.count))
        }
    }
}

/// HTTPS download pinned to each file's `sourceURL` (an immutable revision URL), resumed with Range requests.
public struct HTTPModelSource: ModelSource {
    public let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func fetch(_ file: ModelFile, manifest: ModelManifest, appendingTo partial: URL, from offset: Int64,
                      progress: @Sendable (Int64) -> Void, cancellation: CancellationToken) async throws {
        guard let url = file.sourceURL, url.scheme == "https" else { throw ModelInstallError.invalidManifest("\(file.path): no https sourceURL") }
        var req = URLRequest(url: url)
        if offset > 0 { req.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw ModelInstallError.network("no HTTP response") }
        guard (200..<300).contains(http.statusCode) else { throw ModelInstallError.network("HTTP \(http.statusCode)") }
        let out = try FileHandle(forWritingTo: partial)
        defer { try? out.close() }
        if offset > 0 && http.statusCode != 206 {
            // Server ignored Range and is sending the whole file: restart this file cleanly from zero.
            try out.truncate(atOffset: 0)
            progress(-offset)
        } else {
            try out.seekToEnd()
        }
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        for try await b in bytes {
            buffer.append(b)
            if buffer.count >= 1 << 20 {
                try cancellation.check()
                try out.write(contentsOf: buffer)
                progress(Int64(buffer.count))
                buffer.removeAll(keepingCapacity: true)
            }
        }
        try out.write(contentsOf: buffer)
        progress(Int64(buffer.count))
    }
}

public struct InstallProgress: Sendable, Hashable {
    public enum Phase: String, Sendable { case checkingSpace, downloading, verifying, warmingUp, activating, done }
    public var phase: Phase
    public var bytesDone: Int64
    public var bytesTotal: Int64
    public var currentFile: String?

    public init(phase: Phase, bytesDone: Int64, bytesTotal: Int64, currentFile: String? = nil) {
        self.phase = phase
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.currentFile = currentFile
    }
}

/// Stages, verifies, warms up and atomically activates a model pack. Interrupted installs resume from `.partial`
/// files in the same staging directory; partial or unverified files are never activated.
public final class ModelInstaller: Sendable {
    public let store: ModelPackStore
    /// Extra free space kept beyond the pack size (plan §6 keeps recording space separate from model space).
    public let safetyMarginBytes: Int64
    /// Optional warm-up (e.g. Core ML load / sample transcription) run against the staged pack before activation.
    public let warmUp: (@Sendable (ModelPack, URL) async throws -> Void)?

    public init(store: ModelPackStore, safetyMarginBytes: Int64 = 1 << 30,
                warmUp: (@Sendable (ModelPack, URL) async throws -> Void)? = nil) {
        self.store = store
        self.safetyMarginBytes = safetyMarginBytes
        self.warmUp = warmUp
    }

    /// Disk space needed for an install of `pack` (bytes not yet staged + margin).
    public func requiredBytes(for pack: ModelPack) -> Int64 {
        pack.manifests.reduce(0) { $0 + $1.totalBytes } + safetyMarginBytes
    }

    /// Stable staging directory per pack version so a later attempt resumes rather than restarts.
    func stagingDirectory(for pack: ModelPack) -> URL {
        store.stagingDirectory.appending(path: "\(pack.id)-\(pack.version)")
    }

    public func install(_ pack: ModelPack, from source: any ModelSource, cancellation: CancellationToken = CancellationToken(),
                        progress: @escaping @Sendable (InstallProgress) -> Void = { _ in }) async throws {
        for m in pack.manifests { try validate(m) }
        let total = pack.manifests.reduce(0) { $0 + $1.totalBytes }
        let fm = FileManager.default
        let dest = store.packDirectory(pack.id, pack.version)
        // Same version already on disk: if every file verifies, just (re)activate it. If any file is damaged, fall through
        // and stage a fresh copy, which replaces the damaged one at activation (repair path).
        if fm.fileExists(atPath: dest.path) {
            progress(InstallProgress(phase: .verifying, bytesDone: 0, bytesTotal: total))
            if Self.verify(pack, at: dest) {
                try store.setActive(.init(packID: pack.id, version: pack.version))
                progress(InstallProgress(phase: .done, bytesDone: total, bytesTotal: total))
                return
            }
            if store.isLeased(.init(packID: pack.id, version: pack.version)) {
                throw ModelInstallError.packInUse("damaged pack is in use by a running job; retry when it finishes")
            }
        }
        let staging = stagingDirectory(for: pack)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        // Space check counts only bytes still to be fetched.
        progress(InstallProgress(phase: .checkingSpace, bytesDone: 0, bytesTotal: total))
        var already: Int64 = 0
        for m in pack.manifests { for f in m.files { already += Self.stagedSize(staging, m, f) } }
        if let avail = ModelPackStore.availableBytes(at: store.root) {
            let need = total - already + safetyMarginBytes
            guard avail >= need else { throw ModelInstallError.insufficientSpace(required: need, available: avail) }
        }

        let done = Counter(already)
        for m in pack.manifests {
            for f in m.files {
                try cancellation.check()
                let final = staging.appending(path: m.id.rawValue).appending(path: f.path)
                let partial = final.appendingPathExtension("partial")
                try fm.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: final.path) { continue } // verified on a previous attempt
                if !fm.fileExists(atPath: partial.path) { fm.createFile(atPath: partial.path, contents: nil) }
                var have = (try? fm.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
                if have > f.byteSize { try fm.removeItem(at: partial); fm.createFile(atPath: partial.path, contents: nil); have = 0 }
                if have < f.byteSize {
                    progress(InstallProgress(phase: .downloading, bytesDone: done.value, bytesTotal: total, currentFile: f.path))
                    try await source.fetch(f, manifest: m, appendingTo: partial, from: have, progress: { n in
                        progress(InstallProgress(phase: .downloading, bytesDone: done.add(n), bytesTotal: total, currentFile: f.path))
                    }, cancellation: cancellation)
                }
                progress(InstallProgress(phase: .verifying, bytesDone: done.value, bytesTotal: total, currentFile: f.path))
                let size = (try fm.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? -1
                guard size == f.byteSize else {
                    try? fm.removeItem(at: partial)
                    throw ModelInstallError.sizeMismatch(path: f.path, expected: f.byteSize, actual: size)
                }
                let hash = try ModelPackStore.sha256(of: partial)
                guard hash == f.sha256.lowercased() else {
                    try? fm.removeItem(at: partial) // corrupt bytes are discarded, never activated
                    throw ModelInstallError.hashMismatch(path: f.path, expected: f.sha256, actual: hash)
                }
                guard rename(partial.path, final.path) == 0 else { throw ModelInstallError.io("rename errno \(errno)") }
            }
        }

        try cancellation.check()
        progress(InstallProgress(phase: .warmingUp, bytesDone: total, bytesTotal: total))
        try ContractCoding.encode(pack).write(to: staging.appending(path: "pack.json"))
        if let warmUp { try await warmUp(pack, staging) }

        // Atomic activation: move the whole verified directory into place, then flip active.json.
        progress(InstallProgress(phase: .activating, bytesDone: total, bytesTotal: total))
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) {
            // Repair: the existing copy failed verification above. Swap the verified staging copy in atomically, so the
            // pack path never disappears, then delete the damaged copy (now at the staging path).
            guard renamex_np(staging.path, dest.path, UInt32(RENAME_SWAP)) == 0 else { throw ModelInstallError.io("swap errno \(errno)") }
            try? fm.removeItem(at: staging)
        } else {
            guard rename(staging.path, dest.path) == 0 else { throw ModelInstallError.io("activate errno \(errno)") }
        }
        try store.setActive(.init(packID: pack.id, version: pack.version))
        progress(InstallProgress(phase: .done, bytesDone: total, bytesTotal: total))
    }

    func validate(_ m: ModelManifest) throws {
        do { try m.validatePinning() } catch { throw ModelInstallError.invalidManifest("\(error)") }
        for f in m.files {
            guard !f.path.hasPrefix("/"), !f.path.split(separator: "/").contains("..") else {
                throw ModelInstallError.invalidManifest("unsafe path \(f.path)")
            }
        }
        if let min = OperatingSystemVersion(string: m.minimumOS), !ProcessInfo.processInfo.isOperatingSystemAtLeast(min) {
            throw ModelInstallError.incompatible("\(m.id) requires macOS \(m.minimumOS)")
        }
    }

    /// Full verification of an installed pack directory: every file present with the manifest size and sha256.
    static func verify(_ pack: ModelPack, at dir: URL) -> Bool {
        for m in pack.manifests {
            for f in m.files {
                let url = dir.appending(path: m.id.rawValue).appending(path: f.path)
                guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64, size == f.byteSize,
                      (try? ModelPackStore.sha256(of: url)) == f.sha256.lowercased() else { return false }
            }
        }
        return true
    }

    static func stagedSize(_ staging: URL, _ m: ModelManifest, _ f: ModelFile) -> Int64 {
        let final = staging.appending(path: m.id.rawValue).appending(path: f.path)
        if FileManager.default.fileExists(atPath: final.path) { return f.byteSize }
        return (try? FileManager.default.attributesOfItem(atPath: final.appendingPathExtension("partial").path)[.size] as? Int64) ?? 0
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Int64
    init(_ v: Int64) { self.v = v }
    var value: Int64 { lock.withLock { v } }
    func add(_ n: Int64) -> Int64 { lock.withLock { v += n; return v } }
}

extension OperatingSystemVersion {
    init?(string: String) {
        let p = string.split(separator: ".").compactMap { Int($0) }
        guard !p.isEmpty else { return nil }
        self.init(majorVersion: p[0], minorVersion: p.count > 1 ? p[1] : 0, patchVersion: p.count > 2 ? p[2] : 0)
    }
}
