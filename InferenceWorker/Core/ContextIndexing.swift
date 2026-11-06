public import Foundation
public import Domain
public import Storage

/// Background contextual-search indexing (spec 0010, T112): embeds current chunks that lack a vector of the active
/// encoder, a bounded batch at a time, and publishes through the store's guarded writer. Resumable by construction —
/// the vectors table is the checkpoint (content-keyed), so a restart continues where it stopped and repeated or late
/// jobs are idempotent. Never runs while `pauseReason` says so (recording, transcription, notes, Ask, memory/thermal
/// pressure, low disk); `cancelCurrent()` stops the batch in the worker.
public final class ContextIndexingEngine: @unchecked Sendable {
    public enum Step: Equatable, Sendable {
        /// No usable encoder (pack without it, corrupt, failed to load): semantic search off, keyword lookup only.
        case unavailable(String)
        case paused(String)
        /// Everything in the library has a vector (or failed `maxAttempts` times).
        case idle
        case indexed(Int)
        /// The batch failed; counted per text, retried later.
        case failed(String)
        case cancelled
    }

    public struct Hooks: Sendable {
        public var embed: @Sendable (_ requestID: String, _ texts: [String]) async throws -> EmbedResponse
        public var cancel: @Sendable (_ requestID: String) -> Void
        public var pauseReason: @Sendable () async -> String?
        /// The verified installed encoder (manifest revision, weights sha256), nil when none is usable.
        public var installedEncoder: @Sendable () -> (revision: String, sha256: String)?
        public var freeBytes: @Sendable () -> Int64?
        public init(embed: @escaping @Sendable (String, [String]) async throws -> EmbedResponse, cancel: @escaping @Sendable (String) -> Void,
                    pauseReason: @escaping @Sendable () async -> String?, installedEncoder: @escaping @Sendable () -> (revision: String, sha256: String)?,
                    freeBytes: @escaping @Sendable () -> Int64? = { nil }) {
            self.embed = embed; self.cancel = cancel; self.pauseReason = pauseReason; self.installedEncoder = installedEncoder; self.freeBytes = freeBytes
        }
    }

    /// Texts per worker request (≤ `EmbedRequest.maxTexts`): about 0.5 s of encoder time, so a foreground request waits
    /// at most that long behind a batch and cancellation stops within one batch.
    public static let batchSize = 32
    public static let minimumFreeBytes: Int64 = 500_000_000

    let store: MeetingStore
    let hooks: Hooks
    private let lock = NSLock()
    private var currentRequest: String?
    private var _producer: EncoderProducer?
    /// Called when the worker reports a producer different from the remembered one (model replaced): vectors of other
    /// producers are dropped and everything is re-embedded (versioned rebuild, never mixed).
    public var onProducerChange: (@Sendable (EncoderProducer) -> Void)?

    public init(store: MeetingStore, hooks: Hooks, producer: EncoderProducer?) {
        self.store = store; self.hooks = hooks; _producer = producer
    }

    public var producer: EncoderProducer? { lock.withLock { _producer } }

    /// The remembered producer if it is the installed encoder's; nil when unknown or replaced (→ versioned rebuild).
    public var activeProducer: EncoderProducer? {
        guard let p = producer, let inst = hooks.installedEncoder(), p.revision == inst.revision, p.weightsSHA256 == inst.sha256 else { return nil }
        return p
    }

    public func cancelCurrent() {
        if let id = lock.withLock({ currentRequest }) { hooks.cancel(id) }
    }

    /// One bounded batch.
    public func step() async -> Step {
        guard hooks.installedEncoder() != nil else { return .unavailable("The search model isn't installed.") }
        if let reason = await hooks.pauseReason() { return .paused(reason) }
        if let free = hooks.freeBytes(), free < Self.minimumFreeBytes { return .paused("Not enough free disk space for the search index.") }
        let known = activeProducer
        let pending: [MeetingStore.PendingChunk]
        do { pending = try store.pendingContextChunks(producer: known?.id ?? "unknown", limit: Self.batchSize) } catch { return .failed("\(error)") }
        guard !pending.isEmpty else { return .idle }
        let id = "index-" + UUID().uuidString
        lock.withLock { currentRequest = id }
        defer { lock.withLock { currentRequest = nil } }
        do {
            let r = try await hooks.embed(id, pending.map(\.text))
            if known?.id != r.producer.id {
                lock.withLock { _producer = r.producer }
                try store.dropContextVectors(except: r.producer.id)
                onProducerChange?(r.producer)
            }
            let vectors = r.unpacked()
            guard vectors.count == pending.count else {
                try store.recordContextFailure(pending.map(\.contentHash), producer: r.producer.id, error: "wrong vector count \(vectors.count)")
                return .failed("wrong vector count")
            }
            let n = try store.publishContextVectors(zip(pending, vectors).map { ($0.contentHash, $1) }, producer: r.producer)
            return .indexed(n)
        } catch is CancellationError {
            return .cancelled
        } catch let e as IndexingError {
            if case .cancelled = e { return .cancelled }
            if let p = known { try? store.recordContextFailure(pending.map(\.contentHash), producer: p.id, error: "\(e)") }
            return .failed("\(e)")
        } catch {
            // Worker crash/timeout/transport: not the texts' fault; nothing recorded, retried after a back-off.
            return .failed("\(error)")
        }
    }

    /// Errors the embed hook reports for the texts themselves (recorded as failures) or cancellation.
    public enum IndexingError: Error, Sendable { case cancelled, rejected(String) }

    public func coverage(_ filter: ContextFilter = ContextFilter()) -> IndexCoverage {
        let p = activeProducer?.id
        return (try? store.contextCoverage(filter, producer: p)) ?? IndexCoverage(meetingsInScope: 0, meetingsIndexed: 0, chunks: 0, chunksEmbedded: 0, encoderAvailable: false)
    }
}
