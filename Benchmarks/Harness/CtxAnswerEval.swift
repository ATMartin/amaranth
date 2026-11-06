import Contextual
import Domain
import Foundation
import Notes
import Presentation
import Storage

/// T115/T116: `ctx-eval answer <set.json> <results-dir> <notes.gguf> <encoder.gguf> [--only ids]` — the whole contextual
/// Ask (plan → hybrid retrieval → answer → checker) per question under the 15 s end-to-end deadline, with mechanical
/// checks (terminal state, deadline, citation validity, all-span recall) and a grading sheet for the rubric.
enum CtxAnswerEval {
    struct Row: Codable {
        var id: String, scenario: String, categories: [String], behavior: String, question: String
        var expectedMeaning: String, requiredPoints: [String], forbidden: [String]
        var terminal: String, answer: String, notes: [String], guidance: [String]
        var cited: [String], citationsValid: Bool, refused: Bool, confidence: String?, checkerNote: String?
        var pieces: Int, coveredFinal: Int, coveredCited: Int
        var seconds: Double, planSeconds: Double, retrievalSeconds: Double, answerSeconds: Double, firstTextSeconds: Double?
    }

    static func run(_ args: [String]) async throws -> Int32 {
        let set = try CtxFixtures.load(URL(filePath: args[1]))
        let results = URL(filePath: args[2])
        try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        let only = args.firstIndex(of: "--only").map { Set(args[$0 + 1].split(separator: ",").map(String.init)) }
        let root = FileManager.default.temporaryDirectory.appending(path: "amr-ctxans-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let seeded = try CtxFixtures.seed(set, root: root)
        let models = try CtxRetrieveEval.load(notes: args[3], encoder: args[4])
        try CtxRetrieveEval.index(seeded, models.enc)
        _ = try Answerer.answer(AnswerRequest(requestID: "warm", question: "What was discussed?", passages: [AnswerPassage(label: "x", text: "[00:00] Speaker 1: We discussed the plan.")]),
                                generator: models.gen, cancellation: CancellationToken())
        let retriever = ContextualRetriever(store: seeded.store, models: models, producer: models.enc.producer)
        var rows: [Row] = []
        var previous: [String: (ResolvedConstraints, AnswerTurn)] = [:]
        for q in set.questions where only?.contains(q.id) ?? true {
            let start = ContinuousClock.now
            let deadline = Date().addingTimeInterval(ContextualLimits.deadline - ContextualLimits.deliveryMargin)
            let prev = q.follows.flatMap { previous[$0] }
            let now = q.request_time.flatMap(CtxFixtures.date) ?? seeded.referenceNow
            let (meeting, folder) = CtxFixtures.scope(q, seeded)
            let scope: ContextualRequest.Scope = meeting.map { .meeting($0) } ?? folder.map { .folder($0) } ?? .all
            let req = ContextualRequest(question: q.question, scope: scope, requestTime: now, timeZoneIdentifier: set.timezone, history: prev.map { [$0.1] } ?? [])
            let ev = try await retriever.retrieve(req, previous: prev?.0, requestID: q.id,
                                                  planDeadline: min(Date().addingTimeInterval(ContextualLimits.planningBudget), deadline.addingTimeInterval(-8)))
            let tz = seeded.timeZone
            var row = Row(id: q.id, scenario: q.scenario, categories: q.categories, behavior: q.expected_behavior, question: q.question,
                          expectedMeaning: q.expected_meaning, requiredPoints: q.required_points, forbidden: q.forbidden ?? [],
                          terminal: "", answer: "", notes: ContextualAsk.notes(ev, timeZone: tz), guidance: ContextualAsk.guidance(ev, timeZone: tz),
                          cited: [], citationsValid: true, refused: false, confidence: nil, checkerNote: nil,
                          pieces: 0, coveredFinal: 0, coveredCited: 0, seconds: 0, planSeconds: ev.timings["plan"] ?? 0,
                          retrievalSeconds: ev.timings["retrieval"] ?? 0, answerSeconds: 0, firstTextSeconds: nil)
            func segs(_ ps: [Passage]) -> Set<String> { Set(ps.flatMap { p in p.lines.compactMap { $0.segmentID?.rawValue } + (p.source == .transcript ? [] : [p.ref]) }) }
            let fin = CtxFixtures.allSpansCovered(q, retrieved: segs(ev.passages.map(\.passage)))
            row.pieces = fin.total; row.coveredFinal = fin.covered
            switch ContextualAsk.compose(ev, request: req, requestID: q.id) {
            case .clarify(let text): row.terminal = "clarification"; row.answer = text
            case .noEvidence(let text): row.terminal = "insufficient_evidence"; row.answer = text; row.refused = true
            case .answer(let request, let passages):
                let token = CancellationToken()
                let remaining = deadline.timeIntervalSinceNow
                let timer = DispatchWorkItem { token.cancel() }
                DispatchQueue.global().asyncAfter(deadline: .now() + max(0, remaining), execute: timer)
                let ta = ContinuousClock.now
                do {
                    let r = try Answerer.answer(request, generator: models.gen, cancellation: token)
                    timer.cancel()
                    row.answerSeconds = Perf.seconds(since: ta); row.firstTextSeconds = r.firstTextSeconds
                    row.answer = r.text; row.refused = r.refused; row.confidence = r.confidence.rawValue; row.checkerNote = r.checkerNote
                    row.terminal = r.refused ? "insufficient_evidence" : (ev.coverage.complete || !ev.semantic ? "answered" : "partial")
                    if !r.refused, let v = ContextualAsk.attributionViolation(r.text, ev.constraints) {
                        row.terminal = "clarification"; row.checkerNote = "attribution guard: " + r.text; row.answer = v
                    }
                    let cited = r.citations.compactMap { passages.indices.contains($0 - 1) ? passages[$0 - 1] : nil }
                    row.cited = cited.map { p in "\(p.meetingTitle) (\(p.meetingDate.formatted(date: .abbreviated, time: .omitted))): " + p.lines.filter(\.matched).map { "\($0.speaker ?? "?"): \($0.text)" }.prefix(4).joined(separator: " | ") }
                    row.coveredCited = CtxFixtures.allSpansCovered(q, retrieved: segs(cited)).covered
                    row.citationsValid = try cited.allSatisfy { p in
                        try p.evidence.allSatisfy { e in
                            guard let t = try seeded.store.transcriptRevision(e.revisionID),
                                  let seg = t.applyingTextEdits(try seeded.store.edits(t.meetingID)).segments.first(where: { $0.id == e.segmentID }) else { return false }
                            return seg.words.contains { $0.id == e.firstWord }
                        }
                    }
                    previous[q.id] = (ev.constraints, AnswerTurn(question: q.question, answer: r.text))
                } catch is CancellationError {
                    row.terminal = "timed_out"; row.answer = "(timed out)"
                }
            }
            row.seconds = Perf.seconds(since: start)
            if previous[q.id] == nil { previous[q.id] = (ev.constraints, AnswerTurn(question: q.question, answer: row.answer)) }
            rows.append(row)
            print(String(format: "[ctx-ans] %@ %@ %.1f s (plan %.1f, retr %.2f, ans %.1f) spans %d/%d | %@", q.id, row.terminal, row.seconds, row.planSeconds,
                         row.retrievalSeconds, row.answerSeconds, row.coveredFinal, row.pieces, String(row.answer.prefix(160))))
        }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(rows).write(to: results.appending(path: "answers.json"))
        try sheet(rows, set: set).write(to: results.appending(path: "grading-sheet.md"), atomically: true, encoding: .utf8)
        let t = rows.map(\.seconds).sorted()
        func p(_ q: Double) -> Double { t.isEmpty ? 0 : t[min(t.count - 1, Int(Double(t.count) * q))] }
        let summary = String(format: "# ctx-eval answer — %@ (%d questions)\n\nTerminal within 15 s: %d/%d (max %.1f s; p50 %.1f s, p95 %.1f s). Timeouts: %d. Citations valid: %d/%d answered. Terminal states: %@.\n",
                             set.set, rows.count, rows.filter { $0.seconds <= ContextualLimits.deadline }.count, rows.count, t.last ?? 0, p(0.5), p(0.95),
                             rows.filter { $0.terminal == "timed_out" }.count, rows.filter { $0.citationsValid && !$0.refused && $0.terminal != "clarification" }.count,
                             rows.filter { !$0.refused && $0.terminal != "clarification" }.count,
                             Dictionary(grouping: rows, by: \.terminal).map { "\($0.key) \($0.value.count)" }.sorted().joined(separator: ", "))
        try summary.write(to: results.appending(path: "summary.md"), atomically: true, encoding: .utf8)
        print(summary)
        return 0
    }

    /// The rubric sheet: one block per question with what's expected and what the app answered (graders see both).
    static func sheet(_ rows: [Row], set: CtxFixtures.FixtureSet) -> String {
        var out = "# Grading sheet — \(set.set)\n\nRubric: docs/qualification/milestone-v/t109-semantics.md §3. Grade each: correct / partial / wrong; claims supported: yes / no.\n\n"
        for r in rows {
            out += "## \(r.id) [\(r.behavior)] \(r.categories.joined(separator: ", "))\n\n**Q:** \(r.question)\n\n**Expected:** \(r.expectedMeaning)\n\n"
            out += "**Required points:** " + r.requiredPoints.map { "• \($0)" }.joined(separator: " ") + "\n\n"
            if !r.forbidden.isEmpty { out += "**Forbidden:** " + r.forbidden.map { "• \($0)" }.joined(separator: " ") + "\n\n" }
            out += "**App (\(r.terminal), \(String(format: "%.1f", r.seconds)) s):** \(r.answer)\n\n"
            if !r.notes.isEmpty { out += "**Notes shown:** " + r.notes.joined(separator: " ") + "\n\n" }
            if !r.cited.isEmpty { out += "**Cited:**\n" + r.cited.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
        }
        return out
    }
}
