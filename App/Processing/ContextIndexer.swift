import Foundation
import Observation
import Domain
import Models
import ProcessingCore
import Storage

/// Contextual-search indexing in the app (spec 0010, T112): runs `ContextIndexingEngine` against the XPC worker in
/// the background. New and edited meetings are picked up as soon as their final transcript is committed (`kick()` on
/// every library change), the existing library backfills newest first, and everything yields: no batch starts while a
/// recording, transcription, notes job or Ask is active or the Mac is under memory/thermal pressure, and Record/Ask
/// cancel the running batch (≤ 32 texts, ≈ 0.5 s). State and coverage are published for the UI.
@MainActor @Observable
final class ContextIndexer {
    enum State: Equatable {
        case starting
        case unavailable(String)
        case paused(String)
        case indexing
        case ready
        case failed(String)
    }

    private(set) var state: State = .starting
    private(set) var coverage = IndexCoverage(meetingsInScope: 0, meetingsIndexed: 0, chunks: 0, chunksEmbedded: 0, encoderAvailable: false)
    let engine: ContextIndexingEngine?
    private var loop: Task<Void, Never>?
    private var wake: CheckedContinuation<Void, Never>?
    /// Why indexing must not run now (recording, processing, Ask, pressure), or nil.
    var pauseReason: () -> String? = { nil }
    nonisolated static let producerKey = "contextEncoderProducer"

    /// `remember`: keep the producer in UserDefaults (off for self-tests on temporary libraries).
    init(store: MeetingStore?, worker: WorkerClient, remember: Bool = true) {
        guard let store else { engine = nil; return }
        let remembered = remember ? (UserDefaults.standard.data(forKey: Self.producerKey)).flatMap { try? JSONDecoder().decode(EncoderProducer.self, from: $0) } : nil
        let pause = PauseBox()
        let hooks = ContextIndexingEngine.Hooks(
            embed: { id, texts in
                let r = try await worker.send(.embed(EmbedRequest(requestID: id, texts: texts, query: false, foreground: false)), timeout: .seconds(60))
                switch r {
                case .embeddings(let e): return e
                case .cancelled: throw ContextIndexingEngine.IndexingError.cancelled
                case .failed(_, let code) where code.contains("invalidVector") || code.contains("input longer"):
                    throw ContextIndexingEngine.IndexingError.rejected(code)
                case .failed(_, let code): throw WorkerClient.ClientError.remote(code)
                default: throw WorkerClient.ClientError.remote("unexpected reply")
                }
            },
            cancel: { id in Task { @MainActor in worker.cancel(JobID(id)) } },
            pauseReason: { await MainActor.run { pause.reason?() } },
            installedEncoder: { Self.installedEncoder() },
            freeBytes: { ModelPackStore.availableBytes(at: store.root) })
        let e = ContextIndexingEngine(store: store, hooks: hooks, producer: remembered)
        e.onProducerChange = { p in
            guard remember else { return }
            if let data = try? JSONEncoder().encode(p) { UserDefaults.standard.set(data, forKey: Self.producerKey) }
        }
        engine = e
        pause.reason = { [weak self] in self?.pauseReason() }
    }

    /// Resolved from the active pack (sizes verified; no network): the encoder manifest's revision and weights hash.
    nonisolated static func installedEncoder() -> (revision: String, sha256: String)? {
        var root = ModelPackStore.defaultRoot()
        #if DEBUG
        if let p = UserDefaults.standard.string(forKey: "debugModelsRoot"), !p.isEmpty { root = URL(filePath: p) }   // self-tests only
        #endif
        let registry = LocalModelRegistry(store: ModelPackStore(root: root))
        guard let r = try? registry.resolve(ModelManifestID("qwen3-embedding-0.6b-q8_0")),
              let gguf = r.manifest.files.first(where: { $0.path.hasSuffix(".gguf") }) else { return nil }
        return (r.manifest.sourceRevision, gguf.sha256.lowercased())
    }

    func start() {
        guard loop == nil, let engine else { return }
        loop = Task { [weak self] in
            var backoff = 5.0
            while !Task.isCancelled {
                let step = await engine.step()
                guard let self else { return }
                let cov = await Task.detached(priority: .utility) { engine.coverage() }.value
                self.coverage = cov
                let pause: Double
                switch step {
                case .indexed:
                    self.state = .indexing; backoff = 5; pause = 0.05
                case .idle:
                    self.state = cov.complete ? .ready : .failed("Some text couldn't be prepared for search; Ask finds it only by its exact words.")
                    pause = 120
                case .paused(let r): self.state = .paused(r); pause = 3
                case .unavailable(let r): self.state = .unavailable(r); pause = 60
                case .cancelled: pause = 1
                case .failed(let r):
                    self.state = .failed(r); pause = backoff; backoff = min(backoff * 2, 300)
                }
                await self.sleep(pause)
            }
        }
    }

    /// Library content changed (new final transcript, edit, deletion): look for work now.
    func kick() {
        wake?.resume(); wake = nil
    }

    /// Record or Ask started: stop the running batch in the worker.
    func yieldNow() {
        engine?.cancelCurrent()
    }

    private func sleep(_ seconds: Double) async {
        guard seconds > 0.1 else { try? await Task.sleep(for: .seconds(seconds)); return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            wake = c
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                await MainActor.run { if let w = self?.wake { self?.wake = nil; w.resume() } }
            }
        }
    }

    func stop() { loop?.cancel(); loop = nil; kick() }
}

/// Main-actor pause closure handed to the engine's hooks.
@MainActor private final class PauseBox { var reason: (() -> String?)? }
