import Foundation
import Domain
import Models

/// `Amaranth --self-test embed-worker --model-dir <dir with qwen3-embedding-0.6b-q8_0/>` (Debug builds, T110): proves the
/// packaged XPC worker embeds offline from a verified install. Installs an encoder-only pack from the bundled pack's
/// encoder manifest (hash-verified, from the local directory — no network) into a temporary models root, points the Debug
/// worker at it, and checks dimensions, unit length, determinism, query vs document behavior and the producer identity.
/// The user's installed model pack is never read or changed.
enum EmbedWorkerSelfTest {
    @MainActor static func run(modelDirectory: URL?) async -> Bool {
        #if DEBUG
        guard let dir = modelDirectory, let bundled = ModelSetupModel.bundledPack(),
              let enc = bundled.manifests.first(where: { $0.role == .textEmbedding }) else {
            SelfTest.log(["step": "setup", "error": "--model-dir and a bundled pack with an encoder are required"]); return false
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "amaranth-embed-models-\(UUID())")
        let defaults: UserDefaults? = UserDefaults.standard   // the app's own domain (com.alexmartin.amaranth), read by the worker as a suite
        defer { defaults?.removeObject(forKey: "debugModelsRoot"); try? FileManager.default.removeItem(at: root) }
        do {
            let pack = ModelPack(id: "selftest-encoder", version: bundled.version, profile: bundled.profile, manifests: [enc])
            let t0 = ContinuousClock.now
            try await ModelInstaller(store: ModelPackStore(root: root)).install(pack, from: DirectoryModelSource(root: dir))
            SelfTest.log(["step": "install", "seconds": String(format: "%.1f", Perf.seconds(since: t0)), "ok": "true"])
        } catch { SelfTest.log(["step": "install", "error": "\(error)"]); return false }
        defaults?.set(root.path, forKey: "debugModelsRoot")
        let worker = WorkerClient()
        func embed(_ texts: [String], query: Bool) async throws -> EmbedResponse {
            let r = try await worker.send(.embed(EmbedRequest(requestID: UUID().uuidString, texts: texts, query: query, foreground: true)), timeout: .seconds(60))
            guard case .embeddings(let e) = r else { throw DomainError.invariantViolated("reply \(r)") }
            return e
        }
        do {
            let t0 = ContinuousClock.now
            let docs = try await embed(["Speaker 2: I'd really like to start managing people next year.",
                                        "Speaker 1: The quarterly invoice went out on Tuesday."], query: false)
            let cold = Perf.seconds(since: t0)
            let t1 = ContinuousClock.now
            let q = try await embed(["Who wants to move into management?"], query: true)
            let warm = Perf.seconds(since: t1)
            let again = try await embed(["Who wants to move into management?"], query: true)
            let d = docs.unpacked(), qv = q.unpacked(), qv2 = again.unpacked()
            func cos(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
            let dims = docs.producer.dimensions
            let valid = (d + qv).allSatisfy { VectorCheck.isValid($0, dimensions: dims) }
            let deterministic = qv.count == 1 && qv2.count == 1 && zip(qv[0], qv2[0]).allSatisfy { abs($0 - $1) < 1e-4 }
            let ranks = d.count == 2 && cos(qv[0], d[0]) > cos(qv[0], d[1]) + 0.1
            let producerOK = docs.producer == q.producer && docs.producer.manifestID == enc.id.rawValue
                && docs.producer.revision == enc.sourceRevision && dims == 1024
            let ok = valid && deterministic && ranks && producerOK && docs.loaded && !q.loaded
            SelfTest.log(["step": "embed", "producer": docs.producer.id, "dims": "\(dims)", "valid": "\(valid)", "deterministic": "\(deterministic)",
                          "related": String(format: "%.3f", d.count == 2 ? cos(qv[0], d[0]) : -1), "unrelated": String(format: "%.3f", d.count == 2 ? cos(qv[0], d[1]) : -1),
                          "coldSeconds": String(format: "%.2f", cold), "warmQuerySeconds": String(format: "%.3f", warm),
                          "workerLoaded": "\(docs.loaded)/\(q.loaded)", "ok": "\(ok)"])
            return ok
        } catch { SelfTest.log(["step": "embed", "error": "\(error)"]); return false }
        #else
        SelfTest.log(["step": "setup", "error": "Debug builds only"]); return false
        #endif
    }
}
