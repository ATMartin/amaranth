import Domain
import Foundation
import Notes
import Storage

// T111/T112 scale measurements on an isolated synthetic library (seed with `amaranth-access seed-scale <root> 200 1000`).
//
//   amaranth-bench ctx-scale <library-root> [--fill random|real] [--gguf <encoder.gguf>] [--queries N] [--max-minutes M]
//
// Opens the library (v6 → v7 migration chunks it; timed), reports chunk/vector counts and database growth, fills vectors
// (random unit vectors: storage/scan cost only; real: the pinned encoder, batch 64 as the worker), then times exact
// vector search over all meetings, a folder and a one-week date window, with peak footprint.
enum CtxScale {
    static func dbBytes(_ root: URL) -> Int {
        ["amaranth.sqlite", "amaranth.sqlite-wal"].reduce(0) { $0 + ((try? FileManager.default.attributesOfItem(atPath: root.appending(path: $1).path)[.size] as? Int) ?? 0) }
    }

    static func run(_ args: [String]) throws {
        func value(_ k: String) -> String? { args.firstIndex(of: k).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
        let root = URL(filePath: args[0])
        let before = dbBytes(root)
        let t0 = ContinuousClock.now
        let store = try MeetingStore(root: root)
        print(String(format: "[ctx-scale] open (incl. any migration) %.1f s; db %.0f MB before → %.0f MB", Perf.seconds(since: t0), Double(before) / 1e6, Double(dbBytes(root)) / 1e6))
        var s = try store.contextIndexStats()
        print("[ctx-scale] chunks \(s.chunks), vectors \(s.vectors), chunk text \(s.textBytes / 1_000_000) MB")
        let producer: EncoderProducer
        var encoder: LlamaEmbedder?
        if value("--fill") == "real", let g = value("--gguf") {
            let e = try LlamaEmbedder(gguf: URL(filePath: g), manifestID: ModelManifestID("qwen3-embedding-0.6b-q8_0"), revision: "scale",
                                      weightsSHA256: "06507c7b42688469c4e7298b0a1e16deff06caf291cf0a5b278c308249c3e439", quantization: "q8_0")
            producer = e.producer; encoder = e
        } else {
            producer = EncoderProducer(family: "random", manifestID: "random", revision: "1", weightsSHA256: "-", quantization: "-", dimensions: 1024,
                                       pooling: "-", normalization: "l2", queryInstruction: "", documentPrefix: "", chunking: ChunkingVersion.current, runtime: "random")
        }
        var rng = SystemRandomNumberGenerator()
        func randomUnit() -> [Float] {
            var v = (0..<1024).map { _ in Float.random(in: -1...1, using: &rng) }
            let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot(); v = v.map { $0 / n }; return v
        }
        let maxSeconds = (Double(value("--max-minutes") ?? "25") ?? 25) * 60
        let tf = ContinuousClock.now
        var done = 0, tokens = 0
        while Perf.seconds(since: tf) < maxSeconds {
            let batch = try store.pendingContextChunks(producer: producer.id, limit: 64)
            if batch.isEmpty { break }
            let vecs = try encoder.map { e in tokens += batch.reduce(0) { $0 + e.countTokens($1.text) }; return try e.embed(batch.map(\.text), query: false) }
                ?? batch.map { _ in randomUnit() }
            done += try store.publishContextVectors(zip(batch, vecs).map { ($0.contentHash, $1) }, producer: producer)
            if done % 2048 < 64 { print(String(format: "[ctx-scale] filled %d (%.0f s)", done, Perf.seconds(since: tf))) }
        }
        let fillSeconds = Perf.seconds(since: tf)
        s = try store.contextIndexStats()
        print(String(format: "[ctx-scale] fill %@: %d vectors in %.1f s (%.1f chunks/s%@); vectors %d (%.0f MB); db %.0f MB; footprint peak %.0f MiB",
                     encoder == nil ? "random" : "real", done, fillSeconds, Double(done) / max(fillSeconds, 0.001),
                     encoder == nil ? "" : String(format: ", %.0f tokens/s", Double(tokens) / max(fillSeconds, 0.001)),
                     s.vectors, Double(s.vectorBytes) / 1e6, Double(dbBytes(root)) / 1e6, peakMiB()))
        let cov = try store.contextCoverage(ContextFilter(), producer: producer.id)
        print("[ctx-scale] coverage: \(cov.meetingsIndexed)/\(cov.meetingsInScope) meetings, \(cov.chunksEmbedded)/\(cov.chunks) chunks")
        let meetings = try store.meetings().filter { $0.deletedAt == nil }
        let folder = meetings.compactMap(\.folderID).first
        let starts = meetings.map { $0.clock?.utcOrigin ?? $0.createdAt }.sorted()
        let mid = starts[starts.count / 2]
        let filters: [(String, ContextFilter)] = [("all", ContextFilter()), ("folder", ContextFilter(folder: folder)),
                                                  ("week", ContextFilter(start: mid, end: mid.addingTimeInterval(7 * 86_400)))]
        let n = Int(value("--queries") ?? "40") ?? 40
        let qs = (0..<n).map { i in "who said the \(["budget", "release", "hiring", "pricing", "migration"][i % 5]) was behind \(i)" }
        let qvecs = try encoder.map { try $0.embed(qs, query: true) } ?? qs.map { _ in randomUnit() }
        for (name, f) in filters {
            var times: [Double] = []
            for (i, q) in qvecs.enumerated() {
                let t = ContinuousClock.now
                let hits = try store.vectorSearch(q, producer: producer, filter: f, k: ContextualLimits.candidatesPerList)
                if i > 0 { times.append(Perf.seconds(since: t) * 1000) }
                if i == 0 && hits.isEmpty { print("[ctx-scale] \(name): no hits") }
            }
            times.sort()
            print(String(format: "[ctx-scale] vector search %@ (k=%d): n %d p50 %.0f ms p95 %.0f ms max %.0f ms; footprint peak %.0f MiB", name,
                         ContextualLimits.candidatesPerList, times.count, times[times.count / 2], times[Int(Double(times.count) * 0.95)], times.last ?? 0, peakMiB()))
        }
    }

    static func peakMiB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return kr == KERN_SUCCESS ? Double(info.ledger_phys_footprint_peak) / 1_048_576 : -1
    }
}
