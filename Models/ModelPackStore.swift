import CryptoKit
public import Foundation
public import Domain

/// On-disk layout (Application Support/Amaranth/Models):
///
///     packs/<packID>/<version>/<manifestID>/<files…>   immutable once activated
///     packs/<packID>/<version>/pack.json                the ModelPack that was verified
///     staging/<uuid>/…                                  in-progress installs (never resolved)
///     active.json                                       {packID, version}; replaced atomically
///     leases/<uuid>.lease                               {packID, version, pid}; blocks removal while a job runs
///
/// Inference only ever resolves through `LocalModelRegistry`, which has no network code.
public struct ModelPackStore: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static func defaultRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Amaranth/Models", directoryHint: .isDirectory)
    }

    public var packsDirectory: URL { root.appending(path: "packs") }
    public var stagingDirectory: URL { root.appending(path: "staging") }
    public var leasesDirectory: URL { root.appending(path: "leases") }
    var activeFile: URL { root.appending(path: "active.json") }

    public func packDirectory(_ id: String, _ version: String) -> URL { packsDirectory.appending(path: id).appending(path: version) }

    public struct ActivePack: Codable, Sendable, Hashable {
        public var packID: String
        public var version: String
    }

    public func activePack() -> ActivePack? {
        guard let d = try? Data(contentsOf: activeFile) else { return nil }
        return try? ContractCoding.decode(ActivePack.self, from: d)
    }

    public func installedPack(_ a: ActivePack) throws -> ModelPack {
        try ContractCoding.decode(ModelPack.self, from: Data(contentsOf: packDirectory(a.packID, a.version).appending(path: "pack.json")))
    }

    /// Atomically points `active.json` at an installed pack (write temp + rename).
    func setActive(_ a: ActivePack) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let tmp = root.appending(path: ".active-\(UUID().uuidString).json")
        try ContractCoding.encode(a).write(to: tmp)
        guard rename(tmp.path, activeFile.path) == 0 else { throw ModelInstallError.io("activate rename errno \(errno)") }
    }

    // MARK: Leases

    /// Takes a lease on a pack for the duration of a job; an active lease prevents removal of that pack version.
    public func acquireLease(_ a: ActivePack) throws -> URL {
        try FileManager.default.createDirectory(at: leasesDirectory, withIntermediateDirectories: true)
        let url = leasesDirectory.appending(path: "\(UUID().uuidString).lease")
        struct Lease: Codable, Sendable { var pack: ActivePack; var pid: Int32 }
        try ContractCoding.encode(Lease(pack: a, pid: getpid())).write(to: url)
        return url
    }

    public func releaseLease(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    /// Leases whose owning process is gone are ignored (and cleaned up).
    public func isLeased(_ a: ActivePack) -> Bool {
        struct Lease: Codable, Sendable { var pack: ActivePack; var pid: Int32 }
        let files = (try? FileManager.default.contentsOfDirectory(at: leasesDirectory, includingPropertiesForKeys: nil)) ?? []
        var leased = false
        for f in files where f.pathExtension == "lease" {
            guard let l = try? ContractCoding.decode(Lease.self, from: Data(contentsOf: f)) else { continue }
            if kill(l.pid, 0) != 0 && errno == ESRCH { try? FileManager.default.removeItem(at: f); continue }
            if l.pack == a { leased = true }
        }
        return leased
    }

    /// Removes an inactive, unleased pack version.
    public func remove(_ a: ActivePack) throws {
        guard activePack() != a else { throw ModelInstallError.packInUse("active") }
        guard !isLeased(a) else { throw ModelInstallError.packInUse("leased by a running job") }
        try FileManager.default.removeItem(at: packDirectory(a.packID, a.version))
    }

    /// Deletes abandoned staging directories (never touches activated packs).
    public func cleanStaging(except keep: Set<URL> = []) {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: stagingDirectory, includingPropertiesForKeys: nil)) ?? []
        for d in dirs where !keep.contains(d.standardizedFileURL) { try? FileManager.default.removeItem(at: d) }
    }

    public static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func availableBytes(at url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path) && probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        let v = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage
    }
}

public enum ModelInstallError: Error, Equatable, Sendable {
    case insufficientSpace(required: Int64, available: Int64)
    case hashMismatch(path: String, expected: String, actual: String)
    case sizeMismatch(path: String, expected: Int64, actual: Int64)
    case missingSource(path: String)
    case invalidManifest(String)
    case incompatible(String)
    case cancelled
    case io(String)
    case packInUse(String)
    case network(String)
}
