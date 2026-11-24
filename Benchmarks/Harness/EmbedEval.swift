import Domain
import Foundation
import Notes
import Storage

// T110: encoder candidate recall on the DEV fixtures (never the held-out set).
//
//   amaranth-bench embed-eval <dev.json> <model.gguf> [--dims 1024,512,256] [--quant q8_0] [--out dir]
//
// Chunks every current transcript with chunk-v1, embeds them, and for each question with labeled spans ranks chunks by
// (a) FTS only (the shipped retriever's passages mapped to chunks), (b) vectors only, (c) RRF fusion of both, each
// within the question's UI scope, with and without the oracle meeting-date filter (what T113's resolver should supply).
// A question is a hit if every required evidence piece has a line in the top-10 chunks.
enum EmbedEval {
    struct Indexed { var meeting: MeetingID; var chunk: TranscriptChunk; var start: Date; var folder: FolderID? }

    static func currentLines(_ store: MeetingStore, _ id: MeetingID) throws -> [ChunkSourceLine] {
        guard let m = try store.meeting(id), let tid = m.currentTranscriptRevisionID, let t = try store.transcriptRevision(tid) else { return [] }
        let edits = try store.edits(id)
        let cur = t.applyingTextEdits(edits)
        let names = MeetingStore.speakerNames(cur.speakers, edits)
        return cur.segments.map { seg in
            var ids = seg.speaker.speakerIDs
            for w in seg.words { for x in w.speaker.speakerIDs where !ids.contains(x) { ids.append(x) } }
            let sp = ids.compactMap { names[$0] }.joined(separator: ", ")
            return ChunkSourceLine(segmentID: seg.id, speaker: sp.isEmpty ? nil : sp, words: seg.words.map(\.text), wordIDs: seg.words.map(\.id), start: seg.interval.start)
        }
    }

    static func run(_ args: [String]) throws {
        func value(_ k: String) -> String? { args.firstIndex(of: k).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
        let set = try CtxFixtures.load(URL(filePath: args[0]))
        precondition(set.set != "heldout", "embed-eval tunes: never run it on the held-out set")
        let gguf = URL(filePath: args[1])
        let dimsList = (value("--dims") ?? "1024").split(separator: ",").compactMap { Int($0) }
        let root = FileManager.default.temporaryDirectory.appending(path: "amr-embed-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let seeded = try CtxFixtures.seed(set, root: root)
        var indexed: [Indexed] = []
        for m in try seeded.store.meetings() where m.deletedAt == nil {
            for c in Chunker.chunks(try currentLines(seeded.store, m.id), target: Int(value("--chunk") ?? "") ?? ContextualLimits.chunkTargetTokens, maximum: Int(value("--chunk-max") ?? "") ?? ContextualLimits.chunkMaxTokens) {
                indexed.append(Indexed(meeting: m.id, chunk: c, start: m.clock?.utcOrigin ?? m.createdAt, folder: m.folderID))
            }
        }
        print("[embed-eval] \(indexed.count) chunks from \(Set(indexed.map(\.meeting)).count) meetings")
        let maxDims = dimsList.max() ?? 1024
        var cfg = LlamaEmbedder.Configuration(); cfg.dimensions = maxDims
        let enc = try LlamaEmbedder(gguf: gguf, manifestID: ModelManifestID("eval"), revision: "local", weightsSHA256: "eval",
                                    quantization: value("--quant") ?? "q8_0", configuration: cfg)
        let t0 = ContinuousClock.now
        let docVecs = try enc.embed(indexed.map(\.chunk.text), query: false)
        let docSeconds = Perf.seconds(since: t0)
        let tokens = indexed.map { enc.countTokens($0.chunk.text) }
        print(String(format: "[embed-eval] embedded in %.1f s; chunk tokens p50 %d max %d; truncated %d", docSeconds, tokens.sorted()[tokens.count / 2],
                     tokens.max() ?? 0, enc.truncatedInputs))
        let questions = set.questions.filter { !$0.required_spans.isEmpty }
        let qVecs = try enc.embed(questions.map(\.question), query: true)
        var lines: [String] = []
        for dims in dimsList {
            func cut(_ v: [Float]) -> [Float] {
                let c = Array(v.prefix(dims)); let n = c.reduce(0) { $0 + $1 * $1 }.squareRoot(); return c.map { $0 / n }
            }
            let docs = docVecs.map(cut)
            var hits: [String: [String: Int]] = [:]   // mode -> category -> hits
            var totals: [String: Int] = [:]
            for (qi, q) in questions.enumerated() {
                let (meeting, folder) = CtxFixtures.scope(q, seeded)
                let tz = seeded.timeZone
                let oracle: (Date, Date)? = q.expected_date_range.flatMap { r in
                    var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
                    let f = DateFormatter(); f.calendar = cal; f.timeZone = tz; f.dateFormat = "yyyy-MM-dd"
                    guard let s = f.date(from: r.start), let e = f.date(from: r.end) else { return nil }
                    // Rolling ranges are instants; calendar ranges are inclusive days.
                    return (s, cal.date(byAdding: .day, value: 1, to: e)!)
                }
                func inScope(_ x: Indexed, date: Bool) -> Bool {
                    if let meeting, x.meeting != meeting { return false }
                    if let folder, x.folder != folder { return false }
                    if date, let (s, e) = oracle, !(x.start >= s && x.start < e) { return false }
                    return true
                }
                let qv = cut(qVecs[qi])
                let fts = try Retriever(store: seeded.store, k: 100).search(q.question, in: meeting, folder: folder)
                for date in [false, true] {
                    let pool = indexed.indices.filter { inScope(indexed[$0], date: date) }
                    let vecRank = pool.map { i in (i, zip(qv, docs[i]).reduce(Float(0)) { $0 + $1.0 * $1.1 }) }.sorted { $0.1 > $1.1 }.map(\.0)
                    // FTS passages → the chunks containing their matched lines, in passage order.
                    var ftsRank: [Int] = []
                    var seen = Set<Int>()
                    for p in fts where date == false || oracle.map({ p.meetingDate >= $0.0 && p.meetingDate < $0.1 }) ?? true {
                        let matched = Set(p.lines.filter(\.matched).compactMap(\.segmentID))
                        for i in pool where indexed[i].meeting == p.meetingID && indexed[i].chunk.spans.contains(where: { matched.contains($0.segmentID) }) && seen.insert(i).inserted {
                            ftsRank.append(i)
                        }
                    }
                    var rrf: [Int: Double] = [:]
                    for (r, i) in vecRank.prefix(ContextualLimits.candidatesPerList).enumerated() { rrf[i, default: 0] += 1 / (ContextualLimits.rrfK + Double(r + 1)) }
                    for (r, i) in ftsRank.prefix(ContextualLimits.candidatesPerList).enumerated() { rrf[i, default: 0] += 1 / (ContextualLimits.rrfK + Double(r + 1)) }
                    let hybrid = rrf.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
                    for (mode, rank) in [("fts", ftsRank), ("vector", vecRank), ("hybrid", hybrid)] {
                        var segs = Set<String>()
                        let budget = Int(value("--lines") ?? "100") ?? 100
                        for i in rank { if segs.count >= budget { break }; segs.formUnion(indexed[i].chunk.spans.map(\.segmentID.rawValue)) }
                        let c = CtxFixtures.allSpansCovered(q, retrieved: segs)
                        let key = mode + (date ? "+date" : "")
                        for cat in ["ALL"] + q.categories {
                            if c.covered == c.total { hits[key, default: [:]][cat, default: 0] += 1 }
                            if mode == "fts" && !date { totals[cat, default: 0] += 1 }
                        }
                    }
                }
            }
            let modes = ["fts", "vector", "hybrid", "fts+date", "vector+date", "hybrid+date"]
            lines.append("\n### \(dims) dimensions\n\n| category | n | " + modes.joined(separator: " | ") + " |\n|---|---|" + modes.map { _ in "---|" }.joined())
            for cat in totals.keys.sorted(by: { $0 == "ALL" ? true : $1 == "ALL" ? false : $0 < $1 }) {
                lines.append("| \(cat) | \(totals[cat]!) | " + modes.map { "\(hits[$0]?[cat] ?? 0)" }.joined(separator: " | ") + " |")
            }
        }
        let report = "# embed-eval \(gguf.lastPathComponent) on \(set.set)\n\n\(indexed.count) chunks; documents embedded in " +
            String(format: "%.1f s (%.0f chunks/s); all-span Recall@10 counts (questions with labeled spans).\n", docSeconds, Double(indexed.count) / docSeconds) +
            lines.joined(separator: "\n") + "\n"
        print(report)
        if let out = value("--out") {
            try FileManager.default.createDirectory(at: URL(filePath: out), withIntermediateDirectories: true)
            try report.write(to: URL(filePath: out).appending(path: "embed-eval-\(gguf.deletingPathExtension().lastPathComponent).md"), atomically: true, encoding: .utf8)
        }
    }
}
