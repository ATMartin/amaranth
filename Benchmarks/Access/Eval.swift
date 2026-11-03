import Foundation
import Domain
import Storage
import MeetingAccess

/// Runs the T98 question set: Recall@10 (lexical/name/filter/notes and paraphrase reported separately), citation
/// resolution for every returned line, and the unanswerable/adversarial checks. Writes results.json and report.md.
enum AccessEvalRun {
    struct File: Decodable { var questions: [Q] }
    struct Q: Decodable {
        var id: String; var kind: String; var question: String
        var filter: F?; var meetings: [String]?; var expect: [String]?; var mustNotContain: [String]?; var noPassagesFrom: [String]?; var mustReturnText: String?
    }
    struct F: Decodable { var folder: String?; var participant: String?; var fromDay: Int?; var beforeDay: Int? }
    struct Result: Encodable {
        var id: String; var kind: String; var question: String
        var found: [String: Int?]; var recall: Double?; var passed: Bool?; var error: String?
        var passages: Int; var top: [String]
    }

    static func run(root: URL, questions: URL, out: URL) throws {
        let store = try MeetingStore(root: root)
        let reader = MeetingReader(store: store)
        let map = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: root.appending(path: "eval-map.json")))
        let qs = try JSONDecoder().decode(File.self, from: Data(contentsOf: questions)).questions
        let folders = Dictionary(uniqueKeysWithValues: try store.folders().map { ($0.name, $0.id.rawValue) })
        var results: [Result] = []
        var citations = 0, resolved = 0
        for q in qs {
            var filter = MeetingFilter()
            if let f = q.filter {
                filter.folderID = f.folder.flatMap { folders[$0] }
                filter.participant = f.participant
                filter.startFrom = f.fromDay.map { EvalLibrary.base.addingTimeInterval(Double($0) * 86_400) }
                filter.startBefore = f.beforeDay.map { EvalLibrary.base.addingTimeInterval(Double($0) * 86_400) }
            }
            let req = SearchMeetingsRequest(query: q.question, meetingIDs: q.meetings?.map { Synthetic.id($0).rawValue }, filter: filter, limit: 10)
            var r = Result(id: q.id, kind: q.kind, question: q.question, found: [:], recall: nil, passed: nil, error: nil, passages: 0, top: [])
            do {
                let resp = try reader.searchMeetings(req)
                r.passages = resp.passages.count
                r.top = resp.passages.prefix(3).map { "\($0.source): " + ($0.lines.first(where: \.matched) ?? $0.lines[0]).text }
                for p in resp.passages { for l in p.lines {
                    citations += 1
                    if case .current = reader.resolve(l.citation) { resolved += 1 }
                } }
                if let expect = q.expect {
                    for e in expect {
                        let ref = map[e] ?? e
                        let rank = resp.passages.first { p in p.ref == ref || p.lines.contains { $0.segmentID == ref || $0.blockID == ref } }?.rank
                        r.found[e] = .some(rank)
                    }
                    r.recall = Double(r.found.values.filter { $0 != nil }.count) / Double(expect.count)
                }
                if q.mustNotContain != nil || q.noPassagesFrom != nil || q.mustReturnText != nil {
                    let text = resp.passages.flatMap { $0.lines.map { $0.text.lowercased() } + [$0.meetingTitle.lowercased()] }.joined(separator: "\n")
                    let banned = Set((q.noPassagesFrom ?? []).map { Synthetic.id($0).rawValue })
                    r.passed = !(q.mustNotContain ?? []).contains { text.contains($0.lowercased()) } && !resp.passages.contains { banned.contains($0.meetingID) }
                        && (q.mustReturnText.map { t in resp.passages.contains { $0.lines.contains { $0.text == t } } } ?? true)
                }
            } catch {
                r.error = "\(error)"
                if q.expect == nil { r.passed = (error as? AccessError).map { if case .badQuery = $0 { true } else { false } } ?? false }
            }
            results.append(r)
        }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(results).write(to: out.appending(path: "results.json"))
        func mean(_ kinds: Set<String>) -> (Double, Int) {
            let rs = results.filter { kinds.contains($0.kind) }.compactMap(\.recall)
            return (rs.isEmpty ? 0 : rs.reduce(0, +) / Double(rs.count), rs.count)
        }
        let lexical = mean(["lexical", "name", "acronym", "filter", "notes", "edited", "cross"])
        let para = mean(["paraphrase"])
        let adv = results.filter { $0.kind == "unanswerable" || $0.kind == "adversarial" }
        var md = ["# T98 retrieval evaluation", "",
                  String(format: "- Lexical/name/filter/notes Recall@10: **%.1f%%** over %d questions (target ≥ 85%%)", lexical.0 * 100, lexical.1),
                  String(format: "- Paraphrase Recall@10: **%.1f%%** over %d questions (reported separately; lexical search does not match meaning)", para.0 * 100, para.1),
                  "- Citation resolution: \(resolved)/\(citations) returned lines resolve to current content",
                  "- Unanswerable/adversarial checks passed: \(adv.filter { $0.passed == true }.count)/\(adv.count)", "",
                  "| id | kind | recall / pass | ranks | passages | top match |", "|---|---|---|---|---|---|"]
        for r in results {
            let ranks = r.found.sorted { $0.key < $1.key }.map { kv in "\(kv.key)=" + (kv.value.flatMap { $0 }.map { String($0) } ?? "–") }.joined(separator: " ")
            let score = r.recall.map { String(format: "%.0f%%", $0 * 100) } ?? (r.passed == true ? "pass" : "FAIL")
            md.append("| \(r.id) | \(r.kind) | \(score)\(r.error.map { " (\($0))" } ?? "") | \(ranks) | \(r.passages) | \(r.top.first?.replacingOccurrences(of: "|", with: "/") ?? "") |")
        }
        md += ["", "Unanswerable questions still return the best lexical matches (search never claims an answer exists); the response's",
               "limitations say results are ranked passages, not a complete list, and that the score is not a confidence."]
        try (md.joined(separator: "\n") + "\n").write(to: out.appending(path: "report.md"), atomically: true, encoding: .utf8)
        print(md.prefix(6).joined(separator: "\n"))
    }
}
