public import Foundation
public import Domain

/// A short stretch of a meeting that may answer a question (T53): a window of transcript lines around a match, or one
/// generated-notes item. `evidence` resolves to transcript words, so an answer citing the passage can jump to them.
public struct Passage: Hashable, Sendable {
    public enum Source: String, Sendable { case transcript, notes }
    public struct Line: Hashable, Sendable {
        public var segmentID: TranscriptSegmentID?
        public var start: SessionTime?
        /// Shown speaker name(s) (“Rochelle”, “Speaker 2, Speaker 3”); nil when unknown or for notes.
        public var speaker: String?
        public var text: String
        /// This line matched the question (the others are context).
        public var matched: Bool
        public init(segmentID: TranscriptSegmentID?, start: SessionTime?, speaker: String?, text: String, matched: Bool) {
            self.segmentID = segmentID; self.start = start; self.speaker = speaker; self.text = text; self.matched = matched
        }
    }
    public var meetingID: MeetingID
    public var meetingTitle: String
    public var meetingDate: Date
    public var source: Source
    /// Segment ID of the best-matching line, or the notes item ID.
    public var ref: String
    public var lines: [Line]
    public var evidence: [TranscriptEvidence]
    /// Higher is better (negated bm25 plus small boosts); comparable within one search only.
    public var score: Double

    public init(meetingID: MeetingID, meetingTitle: String, meetingDate: Date, source: Source, ref: String, lines: [Line],
                evidence: [TranscriptEvidence], score: Double) {
        self.meetingID = meetingID; self.meetingTitle = meetingTitle; self.meetingDate = meetingDate; self.source = source
        self.ref = ref; self.lines = lines; self.evidence = evidence; self.score = score
    }
}

/// Finds the passages most likely to answer a natural-language question, using the FTS5 index only (no model, no
/// transcript decoding): bm25 over transcript lines (text and speaker name) and notes items, prefix matching on
/// lightly stemmed question words, ±2-line windows merged when they overlap, top k.
public struct Retriever: Sendable {
    public let store: MeetingStore
    public var k = 12
    /// Transcript lines of context on each side of a matching line.
    public var window = 2
    /// Most rows between the first and last matching line of one passage.
    public var maxSpan = 6
    /// Candidate rows read from FTS before windowing.
    var candidates = 200

    public init(store: MeetingStore, k: Int = 12) {
        self.store = store
        self.k = k
    }

    /// `meeting`: search only that meeting (“This meeting”); nil searches all meetings. `folder` (T42): only meetings
    /// filed there (“This folder”), spread across them like all meetings.
    public func search(_ question: String, in meeting: MeetingID? = nil, folder: FolderID? = nil) throws -> [Passage] {
        let terms = Self.terms(question)
        guard !terms.isEmpty else { return [] }
        // Every user term is a quoted prefix phrase, so user input can never inject FTS syntax.
        let match = "{text speaker} : (" + terms.map { "\"\($0)\"*" }.joined(separator: " OR ") + ")"
        var bindings: [SQLiteDB.Value] = [.text(match)]
        if let meeting { bindings.append(.text(meeting.rawValue)) }
        if let folder { bindings.append(.text(folder.rawValue)) }
        bindings.append(.int(Int64(candidates)))
        return try store.withDB { db in
            let rows = try db.run("""
                SELECT s.rowid AS rid, s.meeting_id, s.kind, s.ref, s.start_ns, s.text, s.speaker, s.evidence,
                       bm25(search_index, 0, 0, 0, 0, 1.0, 0.6, 0) AS score, m.title, m.created_at
                FROM search_index s JOIN meetings m ON m.id = s.meeting_id
                WHERE search_index MATCH ? AND m.deleted_at IS NULL\(meeting == nil ? "" : " AND s.meeting_id = ?")\(folder == nil ? "" : " AND m.folder_id = ?")
                ORDER BY score LIMIT ?
                """, bindings)
            // Meetings whose title or people match get a small boost (“the Leesa 1:1”, “with Andrew”).
            var meetingBoost: [String: Double] = [:]
            var hits: [Hit] = []
            for r in rows {
                guard let mid = r["meeting_id"]?.text, let kind = r["kind"]?.text, let rid = r["rid"]?.int else { continue }
                let score = -(r["score"]?.double ?? 0)
                switch kind {
                case "title", "person": meetingBoost[mid, default: 0] = max(meetingBoost[mid, default: 0], 0.15)
                case "transcript", "notes":
                    hits.append(Hit(rowid: rid, meetingID: mid, kind: kind, ref: r["ref"]?.text ?? "", score: score,
                                    title: r["title"]?.text ?? "", date: Date(timeIntervalSince1970: r["created_at"]?.double ?? 0),
                                    line: Self.line(r, matched: true), evidence: Self.evidence(r)))
                default: break   // speaker rows: the speaker column of their lines already carries the name
                }
            }
            var passages: [Passage] = []
            // Transcript: windows around each hit. Nearby hits share a window while it stays short (at most `maxSpan`
            // matched rows apart), so a run of hits can't chain into one huge passage; the passage keeps its best hit's
            // score plus a little for every further hit inside it. No line appears in two passages: better passages
            // claim their context lines first.
            var windows: [(meeting: String, lo: Int64, hi: Int64, hits: [Hit])] = []
            let reach = Int64(2 * window)
            for h in hits.filter({ $0.kind == "transcript" }).sorted(by: { ($0.meetingID, $0.rowid) < ($1.meetingID, $1.rowid) }) {
                if let i = windows.lastIndex(where: { $0.meeting == h.meetingID && h.rowid <= $0.hi + reach && h.rowid - $0.lo <= Int64(maxSpan) }) {
                    windows[i].lo = min(windows[i].lo, h.rowid); windows[i].hi = max(windows[i].hi, h.rowid); windows[i].hits.append(h)
                } else {
                    windows.append((h.meetingID, h.rowid, h.rowid, [h]))
                }
            }
            var claimed = Set<Int64>()
            for w in windows.sorted(by: { $0.hits.map(\.score).max()! > $1.hits.map(\.score).max()! }) {
                let matched = Set(w.hits.map(\.rowid)).subtracting(claimed)
                guard !matched.isEmpty else { continue }
                let best = w.hits.filter { matched.contains($0.rowid) }.max { $0.score < $1.score }!
                let context = try db.run("""
                    SELECT rowid AS rid, kind, meeting_id, ref, start_ns, text, speaker, evidence FROM search_index
                    WHERE rowid BETWEEN ? AND ?
                    """, [.int(w.lo - Int64(window)), .int(w.hi + Int64(window))])
                    .filter { $0["meeting_id"]?.text == w.meeting && $0["kind"]?.text == "transcript" && !claimed.contains($0["rid"]?.int ?? -1) }
                    .sorted { ($0["start_ns"]?.int ?? 0, $0["rid"]?.int ?? 0) < ($1["start_ns"]?.int ?? 0, $1["rid"]?.int ?? 0) }
                claimed.formUnion(context.compactMap { $0["rid"]?.int })
                let extra = w.hits.filter { matched.contains($0.rowid) }.map(\.score).sorted(by: >).dropFirst().reduce(0) { $0 + $1 * 0.25 }
                passages.append(Passage(meetingID: MeetingID(w.meeting), meetingTitle: best.title, meetingDate: best.date, source: .transcript, ref: best.ref,
                                        lines: context.map { Self.line($0, matched: matched.contains($0["rid"]?.int ?? -1)) },
                                        evidence: context.flatMap(Self.evidence),
                                        score: (best.score + extra) * (1 + meetingBoost[w.meeting, default: 0])))
            }
            for h in hits where h.kind == "notes" {
                passages.append(Passage(meetingID: MeetingID(h.meetingID), meetingTitle: h.title, meetingDate: h.date, source: .notes, ref: h.ref,
                                        lines: [h.line], evidence: h.evidence, score: h.score * (1 + meetingBoost[h.meetingID, default: 0])))
            }
            let ranked = passages.sorted { $0.score > $1.score }
            return meeting == nil ? Self.spread(ranked, k: k) : Array(ranked.prefix(k))
        }
    }

    /// Across meetings (T55): every meeting that matches well (its best passage scores at least `crossMeetingFloor` of the
    /// top one) gets its best passages in turn, so one long meeting can't fill all k slots and a question spanning
    /// meetings sees each of them. Within the result, passages stay grouped by rank round.
    static func spread(_ ranked: [Passage], k: Int, floor: Double = crossMeetingFloor) -> [Passage] {
        guard let top = ranked.first?.score, top > 0 else { return Array(ranked.prefix(k)) }
        var byMeeting: [(MeetingID, [Passage])] = []
        for p in ranked {
            if let i = byMeeting.firstIndex(where: { $0.0 == p.meetingID }) { byMeeting[i].1.append(p) } else { byMeeting.append((p.meetingID, [p])) }
        }
        let strong = byMeeting.filter { ($0.1.first?.score ?? 0) >= top * floor }
        var out: [Passage] = []
        var round = 0
        while out.count < k, strong.contains(where: { $0.1.count > round }) {
            for (_, ps) in strong where ps.count > round && out.count < k { out.append(ps[round]) }
            round += 1
        }
        // Weaker meetings' passages fill any slots left, by score.
        let used = Set(out.map { [$0.meetingID.rawValue, $0.ref, $0.source.rawValue] })
        out += ranked.filter { !used.contains([$0.meetingID.rawValue, $0.ref, $0.source.rawValue]) }.prefix(max(0, k - out.count))
        return out
    }

    /// A meeting's best passage must reach this share of the overall best to be spread in (cross-meeting scope).
    static let crossMeetingFloor = 0.45

    struct Hit {
        var rowid: Int64, meetingID: String, kind: String, ref: String, score: Double, title: String, date: Date
        var line: Passage.Line, evidence: [TranscriptEvidence]
    }

    static func line(_ r: [String: SQLiteDB.Value], matched: Bool) -> Passage.Line {
        let transcript = r["kind"]?.text == "transcript"
        return Passage.Line(segmentID: transcript ? r["ref"]?.text.map(TranscriptSegmentID.init) : nil,
                            start: r["start_ns"]?.int.map { SessionTime(nanoseconds: $0) },
                            speaker: r["speaker"]?.text, text: r["text"]?.text ?? "", matched: matched)
    }

    static func evidence(_ r: [String: SQLiteDB.Value]) -> [TranscriptEvidence] {
        guard let json = r["evidence"]?.text else { return [] }
        return (try? JSONDecoder().decode([TranscriptEvidence].self, from: Data(json.utf8))) ?? []
    }

    // MARK: Query terms

    /// Question words worth matching: lower-cased, stop words dropped, lightly stemmed (“kitchens” → “kitchen”,
    /// “deciding” → “decid”) so the prefix match also finds the other forms. If every word is a stop word, all are kept.
    public static func terms(_ question: String) -> [String] {
        let words = question.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .map { String($0).replacingOccurrences(of: "\"", with: "") }
            .map { $0.hasSuffix("'s") ? String($0.dropLast(2)) : $0 }
            .filter { !$0.isEmpty }
        let content = words.filter { !stopWords.contains($0) && !$0.contains("'") }
        var seen = Set<String>()
        return (content.isEmpty ? words : content).map(stem).filter { seen.insert($0).inserted }
    }

    static func stem(_ w: String) -> String {
        guard w.count > 4 else { return w }
        for suffix in ["ingly", "edly", "ing", "ies", "ied", "ed", "es", "ly", "s"] where w.hasSuffix(suffix) {
            let base = String(w.dropLast(suffix.count))
            if base.count >= 3 { return base }
        }
        return w
    }

    public static let stopWords: Set<String> = [
        "a", "about", "above", "after", "again", "all", "also", "am", "an", "and", "any", "anyone", "anything", "are", "as", "at",
        "be", "been", "before", "being", "both", "but", "by", "can", "could", "did", "do", "does", "doing", "done", "during",
        "each", "else", "ever", "for", "from", "get", "got", "had", "has", "have", "having", "he", "her", "here", "him", "his",
        "how", "i", "if", "in", "into", "is", "it", "its", "just", "let", "me", "meeting", "meetings", "mention", "mentioned",
        "more", "most", "my", "no", "not", "now", "of", "on", "once", "only", "or", "other", "our", "out", "over", "own",
        "please", "said", "same", "say", "says", "she", "should", "so", "some", "someone", "something", "such", "talk", "talked",
        "tell", "than", "that", "the", "their", "them", "then", "there", "these", "they", "thing", "things", "this", "those",
        "through", "to", "too", "under", "until", "up", "us", "very", "was", "we", "were", "what", "whats", "when", "where",
        "which", "while", "who", "whom", "why", "will", "with", "would", "you", "your",
    ]
}
