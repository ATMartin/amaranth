import Foundation
import Domain
import Models
import Storage

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
            let indexOK = await indexing(worker: worker)
            SelfTest.log(["step": "embed", "producer": docs.producer.id, "dims": "\(dims)", "valid": "\(valid)", "deterministic": "\(deterministic)",
                          "related": String(format: "%.3f", d.count == 2 ? cos(qv[0], d[0]) : -1), "unrelated": String(format: "%.3f", d.count == 2 ? cos(qv[0], d[1]) : -1),
                          "coldSeconds": String(format: "%.2f", cold), "warmQuerySeconds": String(format: "%.3f", warm),
                          "workerLoaded": "\(docs.loaded)/\(q.loaded)", "ok": "\(ok)"])
            return ok && indexOK
        } catch { SelfTest.log(["step": "embed", "error": "\(error)"]); return false }
        #else
        SelfTest.log(["step": "setup", "error": "Debug builds only"]); return false
        #endif
    }

    #if DEBUG
    /// T112 through the packaged worker: backfill a temporary library, pause, cancel a running batch, edit, restart.
    @MainActor static func indexing(worker: WorkerClient) async -> Bool {
        let root = FileManager.default.temporaryDirectory.appending(path: "amaranth-index-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        guard let store = try? MeetingStore(root: root) else { return false }
        var ids: [MeetingID] = []
        do {
            for k in 0..<6 {
                let m = MeetingID(); ids.append(m)
                let start = Date().addingTimeInterval(Double(-k) * 86_400)
                try store.upsertMeeting(Meeting(id: m, title: "Index \(k)", createdAt: start, clock: SessionClock(utcOrigin: start, timeZoneIdentifier: "UTC", hostTimeOriginNanos: 0),
                                                captureState: .captured, duration: .seconds(600)))
                let spk = SpeakerID("s\(k)")
                let segs = (0..<120).map { i in
                    let words = "in meeting \(k) line \(i) we talked about the budget the launch and who could help next month".split(separator: " ").enumerated().map { j, w in
                        Word(id: WordID("\(k)-\(i)-\(j)"), text: String(w), interval: .seconds(Double(i) * 5 + Double(j) * 0.2, Double(i) * 5 + Double(j) * 0.2 + 0.1), source: .systemOutput, speaker: .speaker(spk))
                    }
                    return TranscriptSegment(id: TranscriptSegmentID("\(k)-\(i)"), source: .systemOutput, interval: SessionInterval(unchecked: words.first!.interval.start, words.last!.interval.end),
                                             words: words, speaker: .speaker(spk))
                }
                try store.publishTranscript(TranscriptRevision(meetingID: m, kind: .final, stage: .attributed, createdAt: start, producer: ProducerInfo(component: "t", configHash: "t"),
                                                               segments: segs, coverage: [], speakers: [Speaker(id: spk, label: "Speaker 1")]))
            }
        } catch { SelfTest.log(["step": "index", "error": "\(error)"]); return false }
        func wait(_ indexer: ContextIndexer, until: (ContextIndexer) -> Bool, seconds: Double) async -> Bool {
            let t0 = ContinuousClock.now
            while Perf.seconds(since: t0) < seconds { if until(indexer) { return true }; try? await Task.sleep(for: .milliseconds(50)) }
            return false
        }
        // Paused (as while recording): nothing is embedded.
        let indexer = ContextIndexer(store: store, worker: worker, remember: false)
        var paused = true
        indexer.pauseReason = { paused ? "Paused while recording" : nil }
        indexer.start()
        let sawPause = await wait(indexer, until: { if case .paused = $0.state { true } else { false } }, seconds: 5)
        let nothingWhilePaused = (try? store.contextIndexStats().vectors) == 0
        // Resume; cancel a running batch (Record pressed) and time the acknowledgement.
        paused = false
        indexer.kick()
        _ = await wait(indexer, until: { $0.state == .indexing }, seconds: 10)
        let tc = ContinuousClock.now
        paused = true
        indexer.yieldNow()
        let stopped = await wait(indexer, until: { if case .paused = $0.state { true } else { false } }, seconds: 5)
        let cancelSeconds = Perf.seconds(since: tc)
        paused = false
        indexer.kick()
        let t0 = ContinuousClock.now
        let done = await wait(indexer, until: { $0.state == .ready }, seconds: 120)
        let backfill = Perf.seconds(since: t0)
        let cov = indexer.coverage
        // Edit one line: only its chunk is embedded again.
        let tr = (try? store.meeting(ids[2]))??.currentTranscriptRevisionID
        if let tr { try? store.appendEdit(UserEdit(meetingID: ids[2], baseRevisionID: tr, sequence: 1, createdAt: Date(),
                                                    operation: .correctText(WordRange(revisionID: tr, first: WordID("2-5-0"), last: WordID("2-5-0")), replacement: "EDITED"))) }
        indexer.kick()
        let reindexed = await wait(indexer, until: { $0.state == .ready && $0.coverage.complete && (try? store.pendingContextChunks(producer: $0.engine?.producer?.id ?? "", limit: 1).isEmpty) == true }, seconds: 30)
        indexer.stop()
        // Restart: a new indexer with the same producer finds nothing to do.
        let again = ContextIndexer(store: store, worker: worker, remember: false)
        let pendingAfterRestart = (try? store.pendingContextChunks(producer: indexer.engine?.producer?.id ?? "", limit: 10).count) ?? -1
        _ = again
        let ok = sawPause && nothingWhilePaused && stopped && cancelSeconds < 1 && done && cov.complete && reindexed && pendingAfterRestart == 0
        SelfTest.log(["step": "index", "chunks": "\(cov.chunks)", "meetings": "\(cov.meetingsIndexed)/\(cov.meetingsInScope)",
                      "backfillSeconds": String(format: "%.1f", backfill), "cancelAckSeconds": String(format: "%.2f", cancelSeconds),
                      "pausedFirst": "\(sawPause && nothingWhilePaused)", "reindexedAfterEdit": "\(reindexed)", "pendingAfterRestart": "\(pendingAfterRestart)", "ok": "\(ok)"])
        return ok
    }
    #endif
}
