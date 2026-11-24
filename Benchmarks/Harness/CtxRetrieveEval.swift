import Contextual
import Domain
import Foundation
import Notes
import Storage

/// In-process `ContextualModels` for benchmarks: the planner on the notes model's answer context, queries on the encoder.
final class LocalContextModels: ContextualModels, @unchecked Sendable {
    let gen: LlamaRunner
    let enc: LlamaEmbedder
    private let lock = NSLock()
    private var tokens: [String: CancellationToken] = [:]
    init(gen: LlamaRunner, enc: LlamaEmbedder) { self.gen = gen; self.enc = enc }
    func token(_ id: String) -> CancellationToken { lock.withLock { let t = CancellationToken(); tokens[id] = t; return t } }
    func plan(requestID: String, question: String, history: [AnswerTurn]) async throws -> PlanResponse {
        try QueryPlanner.plan(question, history: history, generator: gen, cancellation: token(requestID))
    }
    func embedQueries(requestID: String, texts: [String]) async throws -> EmbedResponse {
        let t0 = ContinuousClock.now
        let v = try enc.embed(texts, query: true, cancellation: token(requestID))
        return EmbedResponse(producer: enc.producer, vectors: EmbedResponse.pack(v), seconds: Perf.seconds(since: t0), loaded: false)
    }
    func cancel(requestID: String) { lock.withLock { tokens[requestID]?.cancel() } }
}

/// T114: `ctx-eval retrieve <set.json> <results-dir> <notes.gguf> <encoder.gguf>` — contextual retrieval per question
/// (plan + hybrid search + context), all-span recall in the top 10 ranked passages and in the final set.
enum CtxRetrieveEval {
    struct Row: Codable {
        var id: String, categories: [String], behavior: String, pieces: Int, top10: Int, final: Int, passages: Int
        var planSeconds: Double, retrievalSeconds: Double, totalSeconds: Double, dateRange: String, people: String, semantic: Bool
    }

    static func load(notes: String, encoder: String, revision: String = "eval") throws -> LocalContextModels {
        let n = try LlamaRunner(gguf: URL(filePath: notes), manifestID: ModelManifestID("qwen3-4b-instruct-2507-q4_k_m"), revision: "local")
        var c = LlamaRunner.Configuration(); c.contextTokens = 3072; c.parallel = 1; c.kvTokens = 3072
        let gen = try LlamaRunner(sharing: n, configuration: c)
        let enc = try LlamaEmbedder(gguf: URL(filePath: encoder), manifestID: ModelManifestID("qwen3-embedding-0.6b-q8_0"), revision: revision,
                                    weightsSHA256: "06507c7b42688469c4e7298b0a1e16deff06caf291cf0a5b278c308249c3e439", quantization: "q8_0")
        _ = try QueryPlanner.plan("warm up", history: [], generator: gen, cancellation: CancellationToken())
        return LocalContextModels(gen: gen, enc: enc)
    }

    /// Embeds every chunk except those of "unindexed" fixture meetings.
    static func index(_ s: CtxFixtures.Seeded, _ enc: LlamaEmbedder) throws {
        while true {
            let batch = try s.store.pendingContextChunks(producer: enc.producer.id, limit: 64, excluding: s.unindexed)
            if batch.isEmpty { break }
            let v = try enc.embed(batch.map(\.text), query: false)
            try s.store.publishContextVectors(zip(batch, v).map { ($0.contentHash, $1) }, producer: enc.producer)
        }
    }

    /// `ctx-eval scale-retrieve <library-root> <notes.gguf> <encoder.gguf> [--queries N]`: contextual retrieval latency on
    /// the scale library (vectors from `ctx-scale --fill real`, producer revision "scale").
    static func scale(_ args: [String]) async throws -> Int32 {
        let store = try MeetingStore(root: URL(filePath: args[1]))
        let models = try load(notes: args[2], encoder: args[3], revision: "scale")
        let n = args.firstIndex(of: "--queries").flatMap { Int(args[$0 + 1]) } ?? 40
        let retriever = ContextualRetriever(store: store, models: models, producer: models.enc.producer)
        let topics = ["budget", "release notes", "hiring plan", "pricing page", "data migration", "mobile app", "status page", "customer survey"]
        let shapes = ["Who said the %@ was behind last week?", "What came up about the %@ over the past week?", "Did anyone take ownership of the %@?",
                      "What was decided on the %@ today?", "Is the %@ on track?"]
        var retrieval: [Double] = [], total: [Double] = [], plan: [Double] = []
        let now = Date(timeIntervalSince1970: 1_788_220_800 + 200 * 3600 + 86_400)
        for i in 0..<n {
            let q = String(format: shapes[i % shapes.count], topics[i % topics.count])
            let t0 = ContinuousClock.now
            let e = try await retriever.retrieve(ContextualRequest(question: q, scope: .all, requestTime: now, timeZoneIdentifier: "UTC"), previous: nil,
                                                 requestID: "s\(i)", planDeadline: Date().addingTimeInterval(ContextualLimits.planningBudget))
            if i == 0 { continue }
            total.append(Perf.seconds(since: t0)); retrieval.append(e.timings["retrieval"] ?? 0); plan.append(e.timings["plan"] ?? 0)
            if i % 10 == 0 { print(String(format: "[ctx-scale-ret] %d %@ passages %d retrieval %.2f s", i, q, e.passages.count, e.timings["retrieval"] ?? 0)) }
        }
        func p(_ a: [Double], _ q: Double) -> Double { let s = a.sorted(); return s[min(s.count - 1, Int(Double(s.count) * q))] }
        print(String(format: "[ctx-scale-ret] n %d; retrieval after planning p50 %.2f s p95 %.2f s max %.2f s; planning p50 %.2f s p95 %.2f s; total p50 %.2f s p95 %.2f s max %.2f s; footprint peak %.0f MiB",
                     retrieval.count, p(retrieval, 0.5), p(retrieval, 0.95), retrieval.max() ?? 0, p(plan, 0.5), p(plan, 0.95), p(total, 0.5), p(total, 0.95), total.max() ?? 0, CtxScale.peakMiB()))
        return 0
    }

    static func run(_ args: [String]) async throws -> Int32 {
        let set = try CtxFixtures.load(URL(filePath: args[1]))
        let results = URL(filePath: args[2])
        try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        let only = args.firstIndex(of: "--only").map { Set(args[$0 + 1].split(separator: ",").map(String.init)) }
        let root = FileManager.default.temporaryDirectory.appending(path: "amr-ctxret-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let seeded = try CtxFixtures.seed(set, root: root)
        let models = try load(notes: args[3], encoder: args[4])
        try index(seeded, models.enc)
        let retriever = ContextualRetriever(store: seeded.store, models: models, producer: models.enc.producer)
        var rows: [Row] = []
        var previous: [String: ResolvedConstraints] = [:]
        var debug: [[String: String]] = []
        for q in set.questions where only?.contains(q.id) ?? true {
            var history: [AnswerTurn] = []
            if let f = q.follows, let prev = set.questions.first(where: { $0.id == f }) { history = [AnswerTurn(question: prev.question, answer: prev.expected_meaning)] }
            let now = q.request_time.flatMap(CtxFixtures.date) ?? seeded.referenceNow
            let (meeting, folder) = CtxFixtures.scope(q, seeded)
            let scope: ContextualRequest.Scope = meeting.map { .meeting($0) } ?? folder.map { .folder($0) } ?? .all
            let req = ContextualRequest(question: q.question, scope: scope, requestTime: now, timeZoneIdentifier: set.timezone, history: history)
            let t0 = ContinuousClock.now
            let ev = try await retriever.retrieve(req, previous: q.follows.flatMap { previous[$0] }, requestID: q.id,
                                                  planDeadline: Date().addingTimeInterval(ContextualLimits.planningBudget))
            let total = Perf.seconds(since: t0)
            previous[q.id] = ev.constraints
            func segs(_ ps: some Sequence<RankedPassage>) -> Set<String> {
                Set(ps.flatMap { r in r.passage.lines.compactMap { $0.segmentID?.rawValue } + (r.passage.source == .transcript ? [] : [r.passage.ref]) })
            }
            let ranked = ev.passages.sorted { $0.rank < $1.rank }
            let top = CtxFixtures.allSpansCovered(q, retrieved: segs(ranked.prefix(10)))
            let fin = CtxFixtures.allSpansCovered(q, retrieved: segs(ranked))
            let dr = ev.constraints.dateRange.map { "\($0.kind.rawValue) \($0.start.formatted(.iso8601))…" } ?? "–"
            let people = ev.constraints.people.map { "\($0.name):\($0.resolution.rawValue)" }.joined(separator: ",")
            rows.append(Row(id: q.id, categories: q.categories, behavior: q.expected_behavior, pieces: top.total, top10: top.covered, final: fin.covered,
                            passages: ev.passages.count, planSeconds: ev.timings["plan"] ?? 0, retrievalSeconds: ev.timings["retrieval"] ?? 0,
                            totalSeconds: total, dateRange: dr, people: people, semantic: ev.semantic))
            debug.append(["id": q.id, "passages": ranked.map { "\($0.rank):\($0.passage.meetingTitle):\($0.passage.lines.first?.segmentID?.rawValue ?? $0.passage.ref)" }.joined(separator: " "),
                          "queries": ev.plan.semanticQueries.joined(separator: " / ")])
            print(String(format: "[ctx-ret] %@ %@ top10 %d/%d final %d/%d (%d passages) plan %.1f s retrieval %.2f s total %.1f s %@ %@", q.id,
                         top.total > 0 && top.covered == top.total ? "HIT " : (top.total == 0 ? "--  " : "miss"), top.covered, top.total, fin.covered, fin.total,
                         ev.passages.count, ev.timings["plan"] ?? 0, ev.timings["retrieval"] ?? 0, total, dr, people))
        }
        func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "–" : String(format: "%d/%d (%.0f%%)", a, b, 100 * Double(a) / Double(b)) }
        var out = "# ctx-eval retrieve — \(set.set) (\(rows.count) questions)\n\nAll-span recall (every required piece has a line in the passages).\n\n"
        out += "| category | n | top 10 | final set |\n|---|---|---|---|\n"
        let cats = ["ALL"] + Array(Set(rows.flatMap(\.categories))).sorted()
        for c in cats {
            let rs = rows.filter { $0.pieces > 0 && (c == "ALL" || $0.categories.contains(c)) }
            out += "| \(c) | \(rs.count) | \(pct(rs.filter { $0.top10 == $0.pieces }.count, rs.count)) | \(pct(rs.filter { $0.final == $0.pieces }.count, rs.count)) |\n"
        }
        let rt = rows.map(\.retrievalSeconds).sorted(), tt = rows.map(\.totalSeconds).sorted(), pt = rows.map(\.planSeconds).sorted()
        func p(_ a: [Double], _ q: Double) -> Double { a.isEmpty ? 0 : a[min(a.count - 1, Int(Double(a.count) * q))] }
        out += String(format: "\nRetrieval after planning p50 %.2f s p95 %.2f s; planning p50 %.2f s p95 %.2f s; total p50 %.2f s p95 %.2f s.\n", p(rt, 0.5), p(rt, 0.95), p(pt, 0.5), p(pt, 0.95), p(tt, 0.5), p(tt, 0.95))
        out += "\nMisses (top 10): " + rows.filter { $0.pieces > 0 && $0.top10 < $0.pieces }.map { "\($0.id) (\($0.top10)/\($0.pieces))" }.joined(separator: ", ") + "\n"
        try out.write(to: results.appending(path: "retrieve-report.md"), atomically: true, encoding: .utf8)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(rows).write(to: results.appending(path: "retrieve-rows.json"))
        try JSONSerialization.data(withJSONObject: debug, options: [.prettyPrinted, .sortedKeys]).write(to: results.appending(path: "retrieve-debug.json"))
        print(out)
        return 0
    }
}

/// T116 R3: contextual retrieval vs the shipped FTS retriever on the T98 labeled library (`amaranth-access seed-eval`),
/// questions with an expected source and a scope the Ask UI offers (all meetings or a folder). Participant/date-window
/// filters are external-API features (T98), not Ask scopes: reported as not applicable.
///   ctx-eval access <library-root> <questions.json> <notes.gguf> <encoder.gguf>
enum CtxAccessEval {
    static func run(_ args: [String]) async throws -> Int32 {
        let root = URL(filePath: args[1])
        let store = try MeetingStore(root: root)
        let map = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: root.appending(path: "eval-map.json")))
        let qs = (try JSONSerialization.jsonObject(with: Data(contentsOf: URL(filePath: args[2]))) as! [String: Any])["questions"] as! [[String: Any]]
        let models = try CtxRetrieveEval.load(notes: args[3], encoder: args[4])
        while true {
            let b = try store.pendingContextChunks(producer: models.enc.producer.id, limit: 64)
            if b.isEmpty { break }
            try store.publishContextVectors(zip(b, try models.enc.embed(b.map(\.text), query: false)).map { ($0.contentHash, $1) }, producer: models.enc.producer)
        }
        let folders = Dictionary(uniqueKeysWithValues: try store.folders().map { ($0.name, $0.id) })
        let retriever = ContextualRetriever(store: store, models: models, producer: models.enc.producer)
        var rows: [(String, String, Bool, Bool)] = []
        var na: [String] = []
        for q in qs {
            guard let expect = q["expect"] as? [String], !expect.isEmpty, let id = q["id"] as? String, let text = q["question"] as? String, let kind = q["kind"] as? String else { continue }
            let filter = q["filter"] as? [String: Any] ?? [:]
            if filter.keys.contains(where: { $0 != "folder" }) || q["meetings"] != nil { na.append(id); continue }
            let folder = (filter["folder"] as? String).flatMap { folders[$0] }
            let want = Set(expect.compactMap { map[$0] })
            func refs(_ ps: [Passage]) -> Set<String> { Set(ps.flatMap { p in p.lines.compactMap { $0.segmentID?.rawValue } + [p.ref] }) }
            let fts = try Retriever(store: store, k: 10).search(text, folder: folder)
            let ev = try await retriever.retrieve(ContextualRequest(question: text, scope: folder.map { .folder($0) } ?? .all, requestTime: Date(), timeZoneIdentifier: "UTC"),
                                                  previous: nil, requestID: id, planDeadline: Date().addingTimeInterval(4.5))
            let ctx = ev.passages.sorted { $0.rank < $1.rank }.prefix(10).map(\.passage)
            rows.append((id, kind, !want.isDisjoint(with: refs(fts)), !want.isDisjoint(with: refs(Array(ctx)))))
            print("[ctx-access] \(id) \(kind) fts \(rows.last!.2) ctx \(rows.last!.3)")
        }
        var out = "# T116 R3 — T98 labeled set: shipped FTS vs contextual retrieval (Recall@10, any expected source)\n\n| kind | n | FTS | contextual |\n|---|---|---|---|\n"
        for k in ["ALL"] + Array(Set(rows.map(\.1))).sorted() {
            let rs = rows.filter { k == "ALL" || $0.1 == k }
            out += "| \(k) | \(rs.count) | \(rs.filter(\.2).count) | \(rs.filter(\.3).count) |\n"
        }
        let lex = rows.filter { !["paraphrase"].contains($0.1) }
        out += "\nLexical/name/acronym/notes/edited/cross/folder (non-paraphrase): FTS \(lex.filter(\.2).count)/\(lex.count), contextual \(lex.filter(\.3).count)/\(lex.count).\n"
        out += "Contextual misses where FTS hit: " + rows.filter { $0.2 && !$0.3 }.map(\.0).joined(separator: ", ") + "\nNot applicable (participant/date-window filter or meeting list): " + na.joined(separator: ", ") + "\n"
        print(out)
        try out.write(to: URL(filePath: args[5]), atomically: true, encoding: .utf8)
        return 0
    }
}
