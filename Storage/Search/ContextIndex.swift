public import Foundation
public import Domain
import Accelerate

/// A stored chunk of a meeting's current transcript (T111).
public struct StoredChunk: Hashable, Sendable {
    public var meetingID: MeetingID
    public var ordinal: Int
    public var contentHash: String
    public var text: String
    public var spans: [ChunkSpan]
    public var firstLine: Int
    public var lastLine: Int
    public var start: SessionTime
    public var revisionID: RevisionID
}

/// Scope of a contextual read, applied in SQL before any vector is read or scored.
public struct ContextFilter: Hashable, Sendable {
    public var meetings: Set<MeetingID>?
    public var folder: FolderID?
    /// Meeting start (`clock.utcOrigin ?? createdAt`) in `[start, end)`.
    public var start: Date?
    public var end: Date?
    public init(meetings: Set<MeetingID>? = nil, folder: FolderID? = nil, start: Date? = nil, end: Date? = nil) {
        self.meetings = meetings; self.folder = folder; self.start = start; self.end = end
    }
}

public struct VectorHit: Hashable, Sendable {
    public var meetingID: MeetingID
    public var ordinal: Int
    public var contentHash: String
    /// Cosine similarity (vectors are unit length). Comparable within one query only; not a confidence.
    public var score: Float
}

/// Derived contextual-search index over current transcripts (spec 0010, T111). Chunks are rewritten with the search
/// index in every content-changing transaction (`reindex`), so hidden, trimmed, corrected-away or deleted text never
/// has a chunk; vectors are keyed by chunk content hash + encoder producer and can only be published for text that a
/// current chunk still holds. Single writer: all writes go through the store's serialized connection.
extension MeetingStore {
    // MARK: Writing chunks (inside the content transaction)

    /// Replaces `meeting`'s chunks from its current transcript (`current`: the decoded, edited revision and shown speaker
    /// names; nil when there is none or the meeting is deleted) and bumps its generation. Vectors no chunk references any
    /// more are removed.
    static func rechunk(_ db: SQLiteDB, _ meeting: MeetingID, _ m: Meeting?, current: (TranscriptRevision, [SpeakerID: String])?) throws {
        let old = Set(try db.run("SELECT content_hash FROM context_chunks WHERE meeting_id=?", [.text(meeting.rawValue)]).compactMap { $0["content_hash"]?.text })
        try db.run("DELETE FROM context_chunks WHERE meeting_id=?", [.text(meeting.rawValue)])
        if let m, m.deletedAt == nil {
            let start = (m.clock?.utcOrigin ?? m.createdAt).timeIntervalSince1970
            try db.run("""
                INSERT INTO context_meeting_state (meeting_id, generation, start_at) VALUES (?, 1, ?)
                ON CONFLICT(meeting_id) DO UPDATE SET generation = generation + 1, start_at = excluded.start_at
                """, [.text(meeting.rawValue), .double(start)])
        } else {
            try db.run("DELETE FROM context_meeting_state WHERE meeting_id=?", [.text(meeting.rawValue)])
        }
        if let (tr, names) = current, m?.deletedAt == nil {
            for c in Chunker.chunks(chunkLines(tr, names), title: m?.title) {
                try db.run("""
                    INSERT INTO context_chunks (meeting_id, ordinal, chunking, content_hash, text, spans, first_line, last_line, start_ns, revision_id)
                    VALUES (?,?,?,?,?,?,?,?,?,?)
                    """, [.text(meeting.rawValue), .int(Int64(c.ordinal)), .text(ChunkingVersion.current), .text(c.contentHash), .text(c.text),
                          .text(String(decoding: try JSONEncoder().encode(c.spans), as: UTF8.self)), .int(Int64(c.firstLine)), .int(Int64(c.lastLine)),
                          .int(c.start.nanoseconds), .text(tr.id.rawValue)])
            }
        }
        try collectOrphanVectors(db, candidates: old)
    }

    /// The current lines in transcript order with shown speaker names (as the transcript pane shows them).
    static func chunkLines(_ tr: TranscriptRevision, _ names: [SpeakerID: String]) -> [ChunkSourceLine] {
        tr.segments.compactMap { seg in
            guard !seg.words.isEmpty else { return nil }
            var ids = seg.speaker.speakerIDs
            for w in seg.words { for x in w.speaker.speakerIDs where !ids.contains(x) { ids.append(x) } }
            let sp = ids.compactMap { names[$0] }.joined(separator: ", ")
            return ChunkSourceLine(segmentID: seg.id, speaker: sp.isEmpty ? nil : sp, words: seg.words.map(\.text), wordIDs: seg.words.map(\.id),
                                   start: seg.interval.start)
        }
    }

    /// Vectors (and failure records) of `candidates` hashes that no chunk references any more.
    static func collectOrphanVectors(_ db: SQLiteDB, candidates: Set<String>) throws {
        for h in candidates where try db.run("SELECT 1 AS x FROM context_chunks WHERE content_hash=? LIMIT 1", [.text(h)]).isEmpty {
            try db.run("DELETE FROM context_vectors WHERE content_hash=?", [.text(h)])
            try db.run("DELETE FROM context_failures WHERE content_hash=?", [.text(h)])
        }
    }

    /// Library v7 migration: chunks for every meeting from current content (no model work, search index untouched).
    static func rechunkAll(_ db: SQLiteDB) throws {
        for row in try db.run("SELECT id, json FROM meetings") {
            // A row that can't be decoded is left unchunked (keyword search still has it) rather than blocking the library.
            guard let id = row["id"]?.text, let blob = row["json"]?.blob, let m = try? ContractCoding.decode(Meeting.self, from: blob) else { continue }
            var current: (TranscriptRevision, [SpeakerID: String])?
            if m.deletedAt == nil, let tid = m.currentTranscriptRevisionID,
               let t = try db.run("SELECT json FROM transcript_revisions WHERE id=?", [.text(tid.rawValue)]).first?["json"]?.blob {
                let edits = try db.run("SELECT json FROM user_edits WHERE meeting_id=? ORDER BY sequence", [.text(id)])
                    .compactMap { $0["json"]?.blob }.map { try ContractCoding.decode(UserEdit.self, from: $0) }
                let tr = try ContractCoding.decode(TranscriptRevision.self, from: t).applyingTextEdits(edits)
                current = (tr, speakerNames(tr.speakers, edits))
            }
            try rechunk(db, MeetingID(id), m, current: current)
        }
    }

    // MARK: Reading chunks

    public func contextChunks(_ meeting: MeetingID) throws -> [StoredChunk] {
        try withDB { db in try Self.chunks(db, "c.meeting_id = ?", [.text(meeting.rawValue)]) }
    }

    /// Chunks by (meeting, ordinal), for context expansion and citations; missing ones (edited away since) are absent.
    public func contextChunks(_ keys: [(MeetingID, Int)]) throws -> [StoredChunk] {
        guard !keys.isEmpty else { return [] }
        return try withDB { db in
            try keys.flatMap { k in try Self.chunks(db, "c.meeting_id = ? AND c.ordinal = ?", [.text(k.0.rawValue), .int(Int64(k.1))]) }
        }
    }

    static func chunks(_ db: SQLiteDB, _ condition: String, _ bindings: [SQLiteDB.Value]) throws -> [StoredChunk] {
        try db.run("""
            SELECT c.meeting_id, c.ordinal, c.content_hash, c.text, c.spans, c.first_line, c.last_line, c.start_ns, c.revision_id
            FROM context_chunks c WHERE \(condition) ORDER BY c.meeting_id, c.ordinal
            """, bindings).compactMap { r in
            guard let m = r["meeting_id"]?.text, let spans = r["spans"]?.text,
                  let decoded = try? JSONDecoder().decode([ChunkSpan].self, from: Data(spans.utf8)) else { return nil }
            return StoredChunk(meetingID: MeetingID(m), ordinal: Int(r["ordinal"]?.int ?? 0), contentHash: r["content_hash"]?.text ?? "",
                               text: r["text"]?.text ?? "", spans: decoded, firstLine: Int(r["first_line"]?.int ?? 0), lastLine: Int(r["last_line"]?.int ?? 0),
                               start: SessionTime(nanoseconds: r["start_ns"]?.int ?? 0), revisionID: RevisionID(r["revision_id"]?.text ?? ""))
        }
    }

    /// Per-meeting index generations (bumped by every content rewrite); compare before using or showing a result.
    public func contextGenerations(_ meetings: Set<MeetingID>) throws -> [MeetingID: Int64] {
        try withDB { db in
            var out: [MeetingID: Int64] = [:]
            for m in meetings {
                if let g = try db.run("SELECT generation FROM context_meeting_state WHERE meeting_id=?", [.text(m.rawValue)]).first?["generation"]?.int { out[m] = g }
            }
            return out
        }
    }

    // MARK: Work for the encoder

    public struct PendingChunk: Hashable, Sendable {
        public var contentHash: String
        public var text: String
        public var meetingID: MeetingID
    }

    /// Chunks without a vector of `producer` (one per distinct text), newest meetings first; texts that failed
    /// `maxAttempts` times are skipped (reported by coverage, retried after `clearContextFailures`).
    public func pendingContextChunks(producer: String, limit: Int, excluding: Set<MeetingID> = [], maxAttempts: Int = 3) throws -> [PendingChunk] {
        try withDB { db in
            var out: [PendingChunk] = []
            var seen = Set<String>()
            try db.forEach("""
                SELECT c.content_hash, c.text, c.meeting_id FROM context_chunks c
                JOIN context_meeting_state s ON s.meeting_id = c.meeting_id
                JOIN meetings m ON m.id = c.meeting_id AND m.deleted_at IS NULL
                LEFT JOIN context_vectors v ON v.content_hash = c.content_hash AND v.producer = ?
                LEFT JOIN context_failures f ON f.content_hash = c.content_hash AND f.producer = ?
                WHERE v.content_hash IS NULL AND (f.attempts IS NULL OR f.attempts < ?)
                ORDER BY s.start_at DESC, c.meeting_id, c.ordinal
                """, [.text(producer), .text(producer), .int(Int64(maxAttempts))]) { st in
                guard out.count < limit, let h = SQLiteDB.columnText(st, 0), let m = SQLiteDB.columnText(st, 2) else { return }
                if excluding.contains(MeetingID(m)) || !seen.insert(h).inserted { return }
                out.append(PendingChunk(contentHash: h, text: SQLiteDB.columnText(st, 1) ?? "", meetingID: MeetingID(m)))
            }
            return out
        }
    }

    /// Stores vectors computed for `items` (content hash → vector). Guarded publication: a vector is stored only if a
    /// current chunk still holds that text and the vector is valid for `producer`; returns how many were stored. An old
    /// job can never bring back edited-away or deleted text, and mixed dimensions are impossible.
    @discardableResult
    public func publishContextVectors(_ items: [(contentHash: String, vector: [Float])], producer: EncoderProducer) throws -> Int {
        try withDB { db in
            try db.transaction {
                var n = 0
                for (h, v) in items where VectorCheck.isValid(v, dimensions: producer.dimensions) {
                    guard !(try db.run("SELECT 1 AS x FROM context_chunks WHERE content_hash=? LIMIT 1", [.text(h)]).isEmpty) else { continue }
                    try db.run("INSERT OR REPLACE INTO context_vectors (content_hash, producer, dims, vector, created_at) VALUES (?,?,?,?,?)",
                               [.text(h), .text(producer.id), .int(Int64(producer.dimensions)), .blob(Self.half(v)), .double(Date().timeIntervalSince1970)])
                    try db.run("DELETE FROM context_failures WHERE content_hash=? AND producer=?", [.text(h), .text(producer.id)])
                    n += 1
                }
                return n
            }
        }
    }

    public func recordContextFailure(_ hashes: [String], producer: String, error: String) throws {
        try withDB { db in
            try db.transaction {
                for h in hashes {
                    try db.run("""
                        INSERT INTO context_failures (content_hash, producer, attempts, error) VALUES (?,?,1,?)
                        ON CONFLICT(content_hash, producer) DO UPDATE SET attempts = attempts + 1, error = excluded.error
                        """, [.text(h), .text(producer), .text(String(error.prefix(300)))])
                }
            }
        }
    }

    public func clearContextFailures(producer: String) throws {
        try withDB { db in _ = try db.run("DELETE FROM context_failures WHERE producer=?", [.text(producer)]) }
    }

    /// Model replacement / rebuild: drops every vector that isn't `keep`'s.
    public func dropContextVectors(except keep: String?) throws {
        try withDB { db in
            try db.transaction {
                try db.run("DELETE FROM context_vectors WHERE producer IS NOT ?", [keep.map { .text($0) } ?? .null])
                try db.run("DELETE FROM context_failures WHERE producer IS NOT ?", [keep.map { .text($0) } ?? .null])
            }
        }
    }

    // MARK: Coverage

    /// How much of `filter`'s scope has vectors of `producer` (nil: no encoder available).
    public func contextCoverage(_ filter: ContextFilter, producer: String?) throws -> IndexCoverage {
        try withDB { db in
            let (where_, b) = Self.scopeSQL(filter)
            var meetings = 0, indexed = 0, chunks = 0, embedded = 0
            try db.forEach("""
                SELECT s.meeting_id, count(c.content_hash), count(v.content_hash) FROM context_meeting_state s
                JOIN meetings m ON m.id = s.meeting_id
                LEFT JOIN context_chunks c ON c.meeting_id = s.meeting_id
                LEFT JOIN context_vectors v ON v.content_hash = c.content_hash AND v.producer = ?
                WHERE \(where_) GROUP BY s.meeting_id
                """, [producer.map { .text($0) } ?? .null] + b) { st in
                let n = Int(SQLiteDB.columnInt(st, 1)), e = Int(SQLiteDB.columnInt(st, 2))
                meetings += 1; chunks += n; embedded += e
                if producer != nil, e == n { indexed += 1 }
            }
            return IndexCoverage(meetingsInScope: meetings, meetingsIndexed: indexed, chunks: chunks, chunksEmbedded: embedded, encoderAvailable: producer != nil)
        }
    }

    /// Meetings in scope whose chunks aren't all embedded.
    public func unindexedMeetings(_ filter: ContextFilter, producer: String) throws -> Set<MeetingID> {
        try withDB { db in
            let (where_, b) = Self.scopeSQL(filter)
            var out = Set<MeetingID>()
            try db.forEach("""
                SELECT s.meeting_id FROM context_meeting_state s JOIN meetings m ON m.id = s.meeting_id
                JOIN context_chunks c ON c.meeting_id = s.meeting_id
                LEFT JOIN context_vectors v ON v.content_hash = c.content_hash AND v.producer = ?
                WHERE \(where_) AND v.content_hash IS NULL GROUP BY s.meeting_id
                """, [.text(producer)] + b) { st in if let m = SQLiteDB.columnText(st, 0) { out.insert(MeetingID(m)) } }
            return out
        }
    }

    // MARK: Exact vector search

    /// The `k` chunks most similar to `query` (unit length) among chunks in `filter`'s scope with a vector of
    /// `producer`. Scope first (SQL), then exact cosine over streamed rows with a bounded top-k: memory doesn't grow
    /// with the library. Every meeting in scope is scanned (no candidate cap).
    public func vectorSearch(_ query: [Float], producer: EncoderProducer, filter: ContextFilter, k: Int) throws -> [VectorHit] {
        guard query.count == producer.dimensions, k > 0 else { return [] }
        return try withDB { db in
            let (where_, b) = Self.scopeSQL(filter)
            var top: [VectorHit] = []
            var buffer = [Float](repeating: 0, count: producer.dimensions)
            var minScore: Float = -.infinity
            try db.forEach("""
                SELECT c.meeting_id, c.ordinal, c.content_hash, v.vector FROM context_chunks c
                JOIN context_meeting_state s ON s.meeting_id = c.meeting_id
                JOIN meetings m ON m.id = c.meeting_id
                JOIN context_vectors v ON v.content_hash = c.content_hash AND v.producer = ? AND v.dims = ?
                WHERE \(where_)
                """, [.text(producer.id), .int(Int64(producer.dimensions))] + b) { st in
                let blob = SQLiteDB.columnBlob(st, 3)
                guard blob.count == producer.dimensions * 2 else { return }
                Self.unhalf(blob, into: &buffer)
                var dot: Float = 0
                vDSP_dotpr(query, 1, buffer, 1, &dot, vDSP_Length(producer.dimensions))
                guard top.count < k || dot > minScore, let m = SQLiteDB.columnText(st, 0) else { return }
                top.append(VectorHit(meetingID: MeetingID(m), ordinal: Int(SQLiteDB.columnInt(st, 1)), contentHash: SQLiteDB.columnText(st, 2) ?? "", score: dot))
                if top.count > k * 2 { top.sort { $0.score > $1.score }; top.removeLast(top.count - k); minScore = top.last!.score }
            }
            top.sort { $0.score != $1.score ? $0.score > $1.score : ($0.meetingID.rawValue, $0.ordinal) < ($1.meetingID.rawValue, $1.ordinal) }
            return Array(top.prefix(k))
        }
    }

    /// WHERE clause over `s` (context_meeting_state) and `m` (meetings): not deleted, in the filter's meetings, folder and
    /// date range.
    static func scopeSQL(_ f: ContextFilter) -> (String, [SQLiteDB.Value]) {
        var parts = ["m.deleted_at IS NULL"]
        var b: [SQLiteDB.Value] = []
        if let ms = f.meetings {
            if ms.isEmpty { parts.append("0") } else {
                parts.append("s.meeting_id IN (" + Array(repeating: "?", count: ms.count).joined(separator: ",") + ")")
                b += ms.map(\.rawValue).sorted().map { .text($0) }
            }
        }
        if let folder = f.folder { parts.append("m.folder_id = ?"); b.append(.text(folder.rawValue)) }
        if let s = f.start { parts.append("s.start_at >= ?"); b.append(.double(s.timeIntervalSince1970)) }
        if let e = f.end { parts.append("s.start_at < ?"); b.append(.double(e.timeIntervalSince1970)) }
        return (parts.joined(separator: " AND "), b)
    }

    static func half(_ v: [Float]) -> Data {
        var h = v.map { Float16($0) }
        return Data(bytes: &h, count: h.count * 2)
    }

    static func unhalf(_ raw: UnsafeRawBufferPointer, into out: inout [Float]) {
        let n = out.count
        raw.withMemoryRebound(to: Float16.self) { h in
            out.withUnsafeMutableBufferPointer { o in
                var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: h.baseAddress!), height: 1, width: vImagePixelCount(n), rowBytes: n * 2)
                var dst = vImage_Buffer(data: o.baseAddress!, height: 1, width: vImagePixelCount(n), rowBytes: n * 4)
                vImageConvert_Planar16FtoPlanarF(&src, &dst, 0)
            }
        }
    }

    /// Stored footprint of the contextual index (diagnostics / scale report).
    public func contextIndexStats() throws -> (chunks: Int, vectors: Int, vectorBytes: Int, textBytes: Int) {
        try withDB { db in
            let c = try db.run("SELECT count(*) AS n, coalesce(sum(length(text) + length(spans)), 0) AS b FROM context_chunks").first
            let v = try db.run("SELECT count(*) AS n, coalesce(sum(length(vector)), 0) AS b FROM context_vectors").first
            return (Int(c?["n"]?.int ?? 0), Int(v?["n"]?.int ?? 0), Int(v?["b"]?.int ?? 0), Int(c?["b"]?.int ?? 0))
        }
    }
}

extension MeetingStore {
    /// Current shown speaker names (renamed or reconciled, not anonymous labels) and attendees per meeting in scope (T113).
    public func nameDirectory(_ filter: ContextFilter) throws -> NameDirectory {
        try withDB { db in
            let (where_, b) = Self.scopeSQL(filter)
            var inScope = Set<MeetingID>()
            try db.forEach("SELECT s.meeting_id FROM context_meeting_state s JOIN meetings m ON m.id = s.meeting_id WHERE \(where_)", b) { st in
                if let m = SQLiteDB.columnText(st, 0) { inScope.insert(MeetingID(m)) }
            }
            var speakers: [String: Set<MeetingID>] = [:], attendees: [String: Set<MeetingID>] = [:]
            try db.forEach("""
                SELECT i.meeting_id, i.kind, i.text FROM search_index i JOIN context_meeting_state s ON s.meeting_id = i.meeting_id
                JOIN meetings m ON m.id = i.meeting_id WHERE i.kind IN ('speaker', 'person') AND \(where_)
                """, b) { st in
                guard let m = SQLiteDB.columnText(st, 0), let k = SQLiteDB.columnText(st, 1), let t = SQLiteDB.columnText(st, 2) else { return }
                if k == "speaker" { speakers[t, default: []].insert(MeetingID(m)) } else { attendees[t, default: []].insert(MeetingID(m)) }
            }
            return NameDirectory(speakers: speakers, attendees: attendees, meetingsInScope: inScope)
        }
    }

    /// Whether current transcript or notes text in scope mentions `name` (a word match, FTS).
    public func mentions(_ name: String, filter: ContextFilter) throws -> Bool {
        let tokens = name.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return false }
        let match = "text : (" + tokens.map { "\"\($0)\"" }.joined(separator: " ") + ")"
        return try withDB { db in
            let (where_, b) = Self.scopeSQL(filter)
            return !(try db.run("""
                SELECT 1 AS x FROM search_index i JOIN context_meeting_state s ON s.meeting_id = i.meeting_id JOIN meetings m ON m.id = i.meeting_id
                WHERE search_index MATCH ? AND i.kind IN ('transcript', 'notes') AND \(where_) LIMIT 1
                """, [.text(match)] + b).isEmpty)
        }
    }
}

extension MeetingStore {
    /// Live meetings in `filter`'s scope (T114: the meeting set handed to FTS, so lexical candidates obey dates too).
    public func contextMeetings(_ filter: ContextFilter) throws -> Set<MeetingID> {
        try withDB { db in
            let (where_, b) = Self.scopeSQL(filter)
            var out = Set<MeetingID>()
            try db.forEach("SELECT s.meeting_id FROM context_meeting_state s JOIN meetings m ON m.id = s.meeting_id WHERE \(where_)", b) { st in
                if let m = SQLiteDB.columnText(st, 0) { out.insert(MeetingID(m)) }
            }
            return out
        }
    }

    /// Current transcript lines of `meeting` covering `segments` plus `context` lines on each side, in order, from the
    /// search index (the same rows citations resolve against). `matched` marks `segments`. Empty when they're gone.
    public func transcriptWindow(_ meeting: MeetingID, segments: [TranscriptSegmentID], context: Int, maxLines: Int = 40)
        throws -> (lines: [Passage.Line], evidence: [TranscriptEvidence]) {
        guard !segments.isEmpty else { return ([], []) }
        return try withDB { db in
            let refs = segments.map(\.rawValue)
            let rows = try db.run("SELECT rowid AS rid, ref FROM search_index WHERE meeting_id = ? AND kind = 'transcript' AND ref IN ("
                                  + Array(repeating: "?", count: refs.count).joined(separator: ",") + ")", [.text(meeting.rawValue)] + refs.map { .text($0) })
            let rids = rows.compactMap { $0["rid"]?.int }
            guard let lo = rids.min(), let hi = rids.max() else { return ([], []) }
            let wanted = Set(refs)
            let window = try db.run("""
                SELECT rowid AS rid, kind, meeting_id, ref, start_ns, text, speaker, evidence FROM search_index
                WHERE rowid BETWEEN ? AND ? AND meeting_id = ? AND kind = 'transcript' ORDER BY rowid
                """, [.int(lo - Int64(context)), .int(min(hi + Int64(context), lo + Int64(maxLines))), .text(meeting.rawValue)])
            let lines = window.map { Retriever.line($0, matched: wanted.contains($0["ref"]?.text ?? "")) }
            return (lines, window.flatMap(Retriever.evidence))
        }
    }

    public struct MeetingMeta: Hashable, Sendable { public var title: String; public var start: Date; public var folder: FolderID? }

    public func meetingMeta(_ ids: Set<MeetingID>) throws -> [MeetingID: MeetingMeta] {
        try withDB { db in
            var out: [MeetingID: MeetingMeta] = [:]
            for id in ids {
                guard let r = try db.run("SELECT m.title, m.folder_id, s.start_at FROM meetings m LEFT JOIN context_meeting_state s ON s.meeting_id = m.id WHERE m.id = ? AND m.deleted_at IS NULL",
                                         [.text(id.rawValue)]).first else { continue }
                out[id] = MeetingMeta(title: r["title"]?.text ?? "", start: Date(timeIntervalSince1970: r["start_at"]?.double ?? 0), folder: r["folder_id"]?.text.map(FolderID.init))
            }
            return out
        }
    }
}
