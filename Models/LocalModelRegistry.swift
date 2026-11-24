public import Foundation
public import Domain

/// Resolves verified local model assets from the active pack. Contains **no network code**: a missing or corrupt
/// model is reported, never repaired implicitly. Record-only capture remains available whatever this returns.
public struct LocalModelRegistry: ModelRegistry {
    public enum Verification: Sendable {
        /// Existence + byte size of every file (fast; default before each job).
        case sizes
        /// Full sha256 of every file (slow; on demand and after suspected corruption).
        case fullHash
    }

    public let store: ModelPackStore
    public let verification: Verification

    public init(store: ModelPackStore, verification: Verification = .sizes) {
        self.store = store
        self.verification = verification
    }

    public enum State: Sendable, Equatable {
        case notInstalled
        case ready(packID: String, version: String)
        case corrupt(ModelManifestID, path: String)
    }

    public func state() -> State {
        guard let active = store.activePack(), let pack = try? store.installedPack(active) else { return .notInstalled }
        for m in pack.manifests {
            do { _ = try resolve(m.id) } catch ModelRegistryError.corrupt(let id, let path) { return .corrupt(id, path: path) }
            catch { return .notInstalled }
        }
        return .ready(packID: active.packID, version: active.version)
    }

    public func resolve(_ id: ModelManifestID) throws -> ResolvedModel {
        guard let active = store.activePack(), let pack = try? store.installedPack(active),
              let manifest = pack.manifests.first(where: { $0.id == id }) else { throw ModelRegistryError.notInstalled(id) }
        let root = store.packDirectory(active.packID, active.version).appending(path: id.rawValue)
        let fm = FileManager.default
        for f in manifest.files {
            let url = root.appending(path: f.path)
            guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int64 else {
                throw ModelRegistryError.corrupt(id, path: f.path)
            }
            guard size == f.byteSize else { throw ModelRegistryError.corrupt(id, path: f.path) }
            if verification == .fullHash, (try? ModelPackStore.sha256(of: url)) != f.sha256.lowercased() {
                throw ModelRegistryError.corrupt(id, path: f.path)
            }
        }
        return ResolvedModel(manifest: manifest, rootURL: root)
    }
}
