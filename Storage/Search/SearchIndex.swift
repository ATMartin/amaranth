public import Foundation
public import Domain

/// One search result: where in which meeting the text matched.
public struct SearchHit: Hashable, Sendable {
    public enum Kind: String, Sendable { case title, transcript, notes, userNotes }
    public var meetingID: MeetingID
    public var meetingTitle: String
    public var kind: Kind
    /// Segment ID (transcript), summary item ID (notes), or revision ID (user notes).
    public var ref: String
    /// Session time of the match for transcript hits.
    public var start: SessionTime?
    /// Short excerpt with the match wrapped in `[` `]`.
    public var snippet: String
}

/// Local SQLite FTS5 search (T11). The index mirrors *current* content only (the meeting's current transcript and
/// summary revisions and latest user notes); it is rewritten whenever that content changes and purged on deletion.
/// The private scratchpad is never indexed.
extension MeetingStore {
    public func search(_ query: String, limit: Int = 50) throws -> [SearchHit] {
        let tokens = query.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }
        // Each token is a quoted prefix term, so user input can never inject FTS syntax.
        let match = tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }.joined(separator: " ")
        return try withDB { db in
            try db.run("""
                SELECT s.meeting_id, s.kind, s.ref, s.start_ns, snippet(search_index, 4, '[', ']', '…', 12) AS snip, m.title
                FROM search_index s JOIN meetings m ON m.id = s.meeting_id
                WHERE search_index MATCH ? AND m.deleted_at IS NULL
                ORDER BY rank LIMIT ?
                """, [.text(match), .int(Int64(limit))]).compactMap { row -> SearchHit? in
                guard let id = row["meeting_id"]?.text, let k = row["kind"]?.text.flatMap(SearchHit.Kind.init(rawValue:)) else { return nil }
                return SearchHit(meetingID: MeetingID(id), meetingTitle: row["title"]?.text ?? "", kind: k, ref: row["ref"]?.text ?? "",
                                 start: row["start_ns"]?.int.map { SessionTime(nanoseconds: $0) }, snippet: row["snip"]?.text ?? "")
            }
        }
    }

    /// Rebuilds the whole index from current content (migration backfill, repair).
    public func rebuildSearchIndex() throws {
        try withDB { db in
            try db.transaction {
                try db.run("DELETE FROM search_index")
                for row in try db.run("SELECT id FROM meetings WHERE deleted_at IS NULL") {
                    if let id = row["id"]?.text { try Self.reindex(db, MeetingID(id)) }
                }
            }
        }
    }

    /// Rows currently indexed for a meeting (tests / diagnostics).
    public func searchRowCount(_ meeting: MeetingID) throws -> Int {
        try withDB { db in Int(try db.run("SELECT count(*) AS n FROM search_index WHERE meeting_id=?", [.text(meeting.rawValue)]).first?["n"]?.int ?? 0) }
    }

    /// Replaces all index rows for `meeting` from its current content. Call inside the transaction that changed it.
    static func reindex(_ db: SQLiteDB, _ meeting: MeetingID) throws {
        try db.run("DELETE FROM search_index WHERE meeting_id=?", [.text(meeting.rawValue)])
        guard let row = try db.run("SELECT json FROM meetings WHERE id=?", [.text(meeting.rawValue)]).first?["json"]?.blob else { return }
        let m = try ContractCoding.decode(Meeting.self, from: row)
        guard m.deletedAt == nil else { return }
        func insert(_ kind: SearchHit.Kind, _ ref: String, _ start: Int64?, _ text: String) throws {
            guard !text.isEmpty else { return }
            try db.run("INSERT INTO search_index (meeting_id, kind, ref, start_ns, text) VALUES (?,?,?,?,?)",
                       [.text(meeting.rawValue), .text(kind.rawValue), .text(ref), start.map { .int($0) } ?? .null, .text(text)])
        }
        try insert(.title, m.id.rawValue, nil, m.title)
        if let tid = m.currentTranscriptRevisionID,
           let blob = try db.run("SELECT json FROM transcript_revisions WHERE id=?", [.text(tid.rawValue)]).first?["json"]?.blob {
            let edits = try db.run("SELECT json FROM user_edits WHERE meeting_id=? ORDER BY sequence", [.text(meeting.rawValue)])
                .compactMap { $0["json"]?.blob }.map { try ContractCoding.decode(UserEdit.self, from: $0) }
            let tr = try ContractCoding.decode(TranscriptRevision.self, from: blob).applyingTextCorrections(edits)
            for seg in tr.segments { try insert(.transcript, seg.id.rawValue, seg.interval.start.nanoseconds, seg.text) }
        }
        if let sid = m.currentSummaryRevisionID,
           let blob = try db.run("SELECT json FROM summary_revisions WHERE id=?", [.text(sid.rawValue)]).first?["json"]?.blob {
            let s = try ContractCoding.decode(SummaryRevision.self, from: blob)
            for item in s.content.allItems where item.kind != .limitation {
                try insert(.notes, item.id.rawValue, nil, [item.title, item.text, item.owner].compactMap { $0 }.joined(separator: " — "))
            }
        }
        if let blob = try db.run("SELECT json FROM manual_notes_revisions WHERE meeting_id=? ORDER BY created_at DESC, rowid DESC LIMIT 1",
                                 [.text(meeting.rawValue)]).first?["json"]?.blob {
            let n = try ContractCoding.decode(ManualNotesRevision.self, from: blob)
            try insert(.userNotes, n.id.rawValue, nil, n.markdown)
        }
    }
}
