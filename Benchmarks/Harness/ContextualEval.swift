import Domain
import Foundation
import Notes
import Presentation
import Storage

// Milestone V evaluation (T109 baseline; later tasks add the contextual pipeline).
//
//   amaranth-bench ctx-eval baseline <set.json> <results-dir> [--answers <model.gguf>] [--only id,id]
//
// baseline: the pipeline as shipped before V (T53 FTS retriever → T54 answer prompt/checker), no date or person
// constraints. Measures all-span Recall@10 before and after prompt fitting; with --answers also generates the answers
// (for grading) and their timings.
final class ResultBox: @unchecked Sendable { var code: Int32 = 0 }

enum CtxEval {
    struct Row: Codable {
        var id: String, scenario: String, categories: [String], behavior: String, question: String
        var pieces: Int, coveredTop10: Int, coveredPostFit: Int, recallHit: Bool, recallHitPostFit: Bool
        var passages: Int, passagesUsed: Int?
        var answer: String?, refused: Bool?, citations: [Int]?, citationsValid: Bool?, checkerNote: String?
        var totalSeconds: Double?, retrievalSeconds: Double
        /// Mechanical proxy only (abstain expected ⇔ refused); real grading uses the rubric.
        var proxyOK: Bool?
    }

    static func main(_ args: [String]) throws -> Int32 {
        if args.first == "plan", args.count >= 4 { return try plan(args) }
        if args.first == "scale-retrieve", args.count >= 4 {
            let box = ResultBox(); let sem = DispatchSemaphore(value: 0)
            Task.detached { box.code = (try? await CtxRetrieveEval.scale(args)) ?? 1; sem.signal() }
            sem.wait(); return box.code
        }
        if args.first == "retrieve", args.count >= 5 {
            let box = ResultBox()
            let sem = DispatchSemaphore(value: 0)
            Task.detached { box.code = (try? await CtxRetrieveEval.run(args)) ?? 1; sem.signal() }
            sem.wait()
            return box.code
        }
        guard args.count >= 3, args[0] == "baseline" else {
            print("usage: ctx-eval baseline <set.json> <results-dir> [--answers <model.gguf>] [--only a,b]"); return 2
        }
        func value(_ k: String) -> String? { args.firstIndex(of: k).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
        let set = try CtxFixtures.load(URL(filePath: args[1]))
        let results = URL(filePath: args[2])
        let only = value("--only").map { Set($0.split(separator: ",").map(String.init)) }
        try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appending(path: "amr-ctx-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let seeded = try CtxFixtures.seed(set, root: root)
        var gen: LlamaRunner?
        if let gguf = value("--answers") {
            let notes = try LlamaRunner(gguf: URL(filePath: gguf), manifestID: ModelManifestID("qwen3-4b-instruct-2507-q4_k_m"), revision: "local")
            var c = LlamaRunner.Configuration(); c.contextTokens = 3072; c.parallel = 1; c.kvTokens = 3072
            gen = try LlamaRunner(sharing: notes, configuration: c)
            _ = try Answerer.answer(AnswerRequest(requestID: "warm", question: "What was discussed?",
                                                  passages: [AnswerPassage(label: "00:00", text: "[00:00] Speaker 1: We discussed the plan.")]),
                                    generator: gen!, cancellation: CancellationToken())
        }
        var rows: [Row] = []
        var answers: [String: AnswerTurn] = [:]
        for q in set.questions where only?.contains(q.id) ?? true {
            let (meeting, folder) = CtxFixtures.scope(q, seeded)
            var history: [AnswerTurn] = []
            if let f = q.follows, let prev = answers[f] { history = [prev] }
            let t0 = ContinuousClock.now
            let found = try Retriever(store: seeded.store).search(AskFollowUp.retrievalQuery(q.question, history: history), in: meeting, folder: folder)
            let retrievalSeconds = Perf.seconds(since: t0)
            func segs(_ ps: some Sequence<Passage>) -> Set<String> {
                Set(ps.flatMap { p in p.lines.compactMap { $0.segmentID?.rawValue } + p.evidence.map(\.segmentID.rawValue) + (p.source == .transcript ? [] : [p.ref]) })
            }
            let top = CtxFixtures.allSpansCovered(q, retrieved: segs(found.prefix(10)))
            var row = Row(id: q.id, scenario: q.scenario, categories: q.categories, behavior: q.expected_behavior, question: q.question,
                          pieces: top.total, coveredTop10: top.covered, coveredPostFit: top.covered,
                          recallHit: top.total > 0 && top.covered == top.total, recallHitPostFit: false, passages: found.count,
                          passagesUsed: nil, totalSeconds: nil, retrievalSeconds: retrievalSeconds)
            let request = AnswerRequest(requestID: q.id, question: q.question, passages: AskPassages.render(found, acrossMeetings: meeting == nil), history: history)
            if let gen {
                let (_, fitted) = Answerer.fittedPrompt(request, generator: gen)
                let post = CtxFixtures.allSpansCovered(q, retrieved: segs(found.prefix(fitted.passages.count)))
                row.coveredPostFit = post.covered
                row.recallHitPostFit = post.total > 0 && post.covered == post.total
                let r = try Answerer.answer(request, generator: gen, cancellation: CancellationToken())
                row.passagesUsed = r.passagesUsed
                row.answer = r.text; row.refused = r.refused; row.citations = r.citations; row.checkerNote = r.checkerNote
                row.totalSeconds = r.totalSeconds + retrievalSeconds
                row.citationsValid = try r.citations.allSatisfy { found.indices.contains($0 - 1) } && r.citations.allSatisfy { c in
                    try found[c - 1].evidence.allSatisfy { e in
                        guard let t = try seeded.store.transcriptRevision(e.revisionID),
                              let seg = t.applyingTextEdits(try seeded.store.edits(t.meetingID)).segments.first(where: { $0.id == e.segmentID }) else { return false }
                        return seg.words.contains { $0.id == e.firstWord }
                    }
                }
                row.proxyOK = q.expected_behavior == "abstain" ? r.refused : !r.refused
                answers[q.id] = AnswerTurn(question: q.question, answer: r.text)
            } else {
                row.recallHitPostFit = row.recallHit
            }
            rows.append(row)
            print(String(format: "[ctx-eval] %@ %@ spans %d/%d post-fit %d/%d %@", q.id, row.recallHit ? "HIT " : "miss", top.covered, top.total,
                         row.coveredPostFit, top.total, row.answer.map { String($0.prefix(100)) } ?? ""))
        }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(rows).write(to: results.appending(path: "rows.json"))
        try report(rows, set: set, gen: gen != nil).write(to: results.appending(path: "report.md"), atomically: true, encoding: .utf8)
        print(try String(contentsOf: results.appending(path: "report.md"), encoding: .utf8))
        return 0
    }

    /// T113: `ctx-eval plan <set.json> <results-dir> <model.gguf>`: the local planner + deterministic constraints per
    /// question; resolved meeting-date ranges are compared with the labeled ones (local inclusive dates).
    static func plan(_ args: [String]) throws -> Int32 {
        let set = try CtxFixtures.load(URL(filePath: args[1]))
        let results = URL(filePath: args[2])
        try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appending(path: "amr-ctxplan-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let seeded = try CtxFixtures.seed(set, root: root)
        let notes = try LlamaRunner(gguf: URL(filePath: args[3]), manifestID: ModelManifestID("qwen3-4b-instruct-2507-q4_k_m"), revision: "local")
        var c = LlamaRunner.Configuration(); c.contextTokens = 3072; c.parallel = 1; c.kvTokens = 3072
        let gen = try LlamaRunner(sharing: notes, configuration: c)
        _ = try QueryPlanner.plan("warm up", history: [], generator: gen, cancellation: CancellationToken())
        var cal = Calendar(identifier: .gregorian); cal.timeZone = seeded.timeZone
        let df = DateFormatter(); df.calendar = cal; df.timeZone = seeded.timeZone; df.dateFormat = "yyyy-MM-dd"
        var lines: [String] = ["| id | categories | plan s | fallback | date expected | date resolved | ok | people | queries |", "|---|---|---|---|---|---|---|---|---|"]
        var dateOK = 0, dateN = 0, times: [Double] = [], fallbacks = 0
        var constraints: [String: ResolvedConstraints] = [:]
        var jsonRows: [[String: String]] = []
        for q in set.questions {
            var history: [AnswerTurn] = []
            if let f = q.follows, let prev = set.questions.first(where: { $0.id == f }) { history = [AnswerTurn(question: prev.question, answer: prev.expected_meaning)] }
            let now = q.request_time.flatMap(CtxFixtures.date) ?? seeded.referenceNow
            let r = try QueryPlanner.plan(q.question, history: history, generator: gen, cancellation: CancellationToken())
            times.append(r.seconds); if r.fallback { fallbacks += 1 }
            let (meeting, folder) = CtxFixtures.scope(q, seeded)
            let filter = ContextFilter(meetings: meeting.map { [$0] }, folder: folder)
            let dir = try seeded.store.nameDirectory(filter)
            let res = ConstraintResolver.resolve(question: q.question, plan: r.plan, now: now, timeZone: seeded.timeZone,
                                                 previous: q.follows.flatMap { constraints[$0] }, directory: dir, accountName: nil,
                                                 mentioned: { (try? seeded.store.mentions($0, filter: filter)) ?? false })
            constraints[q.id] = res
            let got = res.dateRange.map { "\(df.string(from: $0.start))…\(df.string(from: $0.end.addingTimeInterval(-1)))" } ?? "–"
            let want = q.expected_date_range.map { "\($0.start)…\($0.end)" } ?? "–"
            let ok = got == want
            dateN += 1; if ok { dateOK += 1 }
            let people = res.people.map { "\($0.name):\($0.role.rawValue)/\($0.resolution.rawValue)" }.joined(separator: ", ")
            lines.append("| \(q.id) | \(q.categories.joined(separator: " ")) | \(String(format: "%.1f", r.seconds)) | \(r.fallback) | \(want) | \(got) | \(ok ? "✓" : "✗") | \(people) | \(r.plan.semanticQueries.joined(separator: " / ").replacingOccurrences(of: "|", with: "/")) |")
            jsonRows.append(["id": q.id, "plan": String(decoding: try JSONEncoder().encode(r.plan), as: UTF8.self), "seconds": String(r.seconds), "dateOK": "\(ok)"])
            print("[ctx-plan] \(q.id) \(ok ? "date ok " : "DATE ✗ ") \(String(format: "%.1f s", r.seconds)) \(people) | \(r.plan.semanticQueries.first ?? "-")")
        }
        times.sort()
        let head = String(format: "# ctx-eval plan — %@\n\nMeeting-date constraint correct: %d/%d. Planner p50 %.2f s, p95 %.2f s, max %.2f s; fallbacks %d.\n\n",
                          set.set, dateOK, dateN, times[times.count / 2], times[Int(Double(times.count) * 0.95)], times.last ?? 0, fallbacks)
        try (head + lines.joined(separator: "\n") + "\n").write(to: results.appending(path: "plan-report.md"), atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: jsonRows, options: [.prettyPrinted, .sortedKeys]).write(to: results.appending(path: "plans.json"))
        print(head)
        return 0
    }

    static func report(_ rows: [Row], set: CtxFixtures.FixtureSet, gen: Bool) -> String {
        func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "–" : String(format: "%d/%d (%.0f%%)", a, b, 100 * Double(a) / Double(b)) }
        let withSpans = rows.filter { $0.pieces > 0 }
        var out = "# ctx-eval baseline — \(set.set) (\(rows.count) questions)\n\n"
        out += "Pipeline: shipped T53 FTS retriever + T54 answer prompt/checker; no date/person constraints.\n\n"
        out += "| Category | n (with spans) | all-span Recall@10 | after prompt fitting |" + (gen ? " proxy OK |" : "") + "\n|---|---|---|---|" + (gen ? "---|" : "") + "\n"
        var cats = Array(Set(rows.flatMap(\.categories))).sorted()
        cats.insert("ALL", at: 0)
        for c in cats {
            let rs = c == "ALL" ? rows : rows.filter { $0.categories.contains(c) }
            let sp = rs.filter { $0.pieces > 0 }
            out += "| \(c) | \(sp.count) | \(pct(sp.filter(\.recallHit).count, sp.count)) | \(pct(sp.filter(\.recallHitPostFit).count, sp.count)) |"
            if gen { out += " \(pct(rs.filter { $0.proxyOK == true }.count, rs.count)) |" }
            out += "\n"
        }
        out += "\nBy expected behavior:\n\n| behavior | n | Recall@10 (with spans) |" + (gen ? " proxy OK |" : "") + "\n|---|---|---|" + (gen ? "---|" : "") + "\n"
        for b in ["answer", "qualify", "partial", "clarify", "abstain"] {
            let rs = rows.filter { $0.behavior == b }
            guard !rs.isEmpty else { continue }
            let sp = rs.filter { $0.pieces > 0 }
            out += "| \(b) | \(rs.count) | \(pct(sp.filter(\.recallHit).count, sp.count)) |" + (gen ? " \(pct(rs.filter { $0.proxyOK == true }.count, rs.count)) |" : "") + "\n"
        }
        let t = rows.map(\.retrievalSeconds).sorted()
        out += String(format: "\nRetrieval p50 %.0f ms, max %.0f ms.", 1000 * (t.isEmpty ? 0 : t[t.count / 2]), 1000 * (t.last ?? 0))
        if gen {
            let tt = rows.compactMap(\.totalSeconds).sorted()
            out += String(format: " Retrieval+answer p50 %.1f s, max %.1f s. Citations valid: %@.", tt.isEmpty ? 0 : tt[tt.count / 2], tt.last ?? 0,
                          pct(rows.filter { $0.citationsValid != false }.count, rows.count))
        }
        out += "\n\nMisses (all-span Recall@10): " + withSpans.filter { !$0.recallHit }.map { "\($0.id) (\($0.coveredTop10)/\($0.pieces))" }.joined(separator: ", ") + "\n"
        return out
    }
}
