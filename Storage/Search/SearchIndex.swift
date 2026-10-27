public import Foundation
public import Domain

/// One search result: where in which meeting the text matched.
public struct SearchHit: Hashable, Sendable {
    public enum Kind: String, Sendable { case title, transcript, notes, userNotes, speaker, person }
    public var meetingID: MeetingID
    public var meetingTitle: String
    public var kind: Kind
    /// Segment ID (transcript), summary item ID (notes), or revision ID (user notes).
    public var ref: String
    /// Session time of the match for transcript hits.
    public var start: SessionTime?
    /// Short excerpt with the match wrapped in `[` `]`.
    public var snippet: String

    public init(meetingID: MeetingID, meetingTitle: String, kind: Kind, ref: String, start: SessionTime?, snippet: String) {
        self.meetingID = meetingID
        self.meetingTitle = meetingTitle
        self.kind = kind
        self.ref = ref
        self.start = start
        self.snippet = snippet
    }
}

/// Local SQLite FTS5 search (T11). The index mirrors *current* content only (the meeting's current transcript and
/// summary revisions and latest user notes); it is rewritten whenever that content changes and purged on deletion.
/// The private scratchpad is never indexed.
extension MeetingStore {
    /// `meeting`: only that meeting's rows (the ask field's "This meeting" scope); nil searches every meeting.
    /// `anyTerm`: match lines with any of the words (ranked by bm25) instead of all of them.
    public func search(_ query: String, in meeting: MeetingID? = nil, anyTerm: Bool = false, limit: Int = 50) throws -> [SearchHit] {
        let tokens = query.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }
        // Each token is a quoted prefix term, so user input can never inject FTS syntax.
        // Only the text column: a speaker's name must not match every one of their lines here (the retriever uses it).
        let match = "text : (" + tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }.joined(separator: anyTerm ? " OR " : " ") + ")"
        var bindings: [SQLiteDB.Value] = [.text(match)]
        if let meeting { bindings.append(.text(meeting.rawValue)) }
        bindings.append(.int(Int64(limit)))
        return try withDB { db in
            try db.run("""
                SELECT s.meeting_id, s.kind, s.ref, s.start_ns, snippet(search_index, 4, '[', ']', '…', 12) AS snip, m.title
                FROM search_index s JOIN meetings m ON m.id = s.meeting_id
                WHERE search_index MATCH ? AND m.deleted_at IS NULL\(meeting == nil ? "" : " AND s.meeting_id = ?")
                ORDER BY rank LIMIT ?
                """, bindings).compactMap { row -> SearchHit? in
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
    /// Transcript rows are inserted in transcript order, so a segment's neighbours are the adjacent rowids (the
    /// retriever's ±2-line windows rely on this).
    static func reindex(_ db: SQLiteDB, _ meeting: MeetingID) throws {
        try db.run("DELETE FROM search_index WHERE meeting_id=?", [.text(meeting.rawValue)])
        guard let row = try db.run("SELECT json FROM meetings WHERE id=?", [.text(meeting.rawValue)]).first?["json"]?.blob else { return }
        let m = try ContractCoding.decode(Meeting.self, from: row)
        guard m.deletedAt == nil else { return }
        func insert(_ kind: SearchHit.Kind, _ ref: String, _ start: Int64?, _ text: String, speaker: String? = nil, evidence: [TranscriptEvidence] = []) throws {
            guard !text.isEmpty else { return }
            let refs: SQLiteDB.Value = evidence.isEmpty ? .null : .text(String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self))
            try db.run("INSERT INTO search_index (meeting_id, kind, ref, start_ns, text, speaker, evidence) VALUES (?,?,?,?,?,?,?)",
                       [.text(meeting.rawValue), .text(kind.rawValue), .text(ref), start.map { .int($0) } ?? .null, .text(text),
                        speaker.map { .text($0) } ?? .null, refs])
        }
        try insert(.title, m.id.rawValue, nil, m.title)
        for p in m.people { try insert(.person, p.name, nil, p.name) }
        if let tid = m.currentTranscriptRevisionID,
           let blob = try db.run("SELECT json FROM transcript_revisions WHERE id=?", [.text(tid.rawValue)]).first?["json"]?.blob {
            let edits = try db.run("SELECT json FROM user_edits WHERE meeting_id=? ORDER BY sequence", [.text(meeting.rawValue)])
                .compactMap { $0["json"]?.blob }.map { try ContractCoding.decode(UserEdit.self, from: $0) }
            let tr = try ContractCoding.decode(TranscriptRevision.self, from: blob).applyingTextCorrections(edits)
            let names = speakerNames(tr.speakers, edits)
            for sp in tr.speakers { if let name = names[sp.id], name != sp.label { try insert(.speaker, sp.id.rawValue, nil, name) } }
            for seg in tr.segments {
                var ids = seg.speaker.speakerIDs
                for w in seg.words { for id in w.speaker.speakerIDs where !ids.contains(id) { ids.append(id) } }
                let speaker = ids.compactMap { names[$0] }.joined(separator: ", ")
                let evidence = seg.words.first.map { [TranscriptEvidence(revisionID: tr.id, segmentID: seg.id, firstWord: $0.id, lastWord: seg.words.last!.id)] } ?? []
                try insert(.transcript, seg.id.rawValue, seg.interval.start.nanoseconds, seg.text, speaker: speaker.isEmpty ? nil : speaker, evidence: evidence)
            }
        }
        if let sid = m.currentSummaryRevisionID,
           let blob = try db.run("SELECT json FROM summary_revisions WHERE id=?", [.text(sid.rawValue)]).first?["json"]?.blob {
            let s = try ContractCoding.decode(SummaryRevision.self, from: blob)
            for item in s.content.allItems where item.kind != .limitation {
                let evidence = (item.evidence + item.ownerEvidence).compactMap { if case .transcript(let e) = $0 { e } else { nil } }
                try insert(.notes, item.id.rawValue, nil, [item.title, item.text, item.owner].compactMap { $0 }.joined(separator: " — "), evidence: evidence)
            }
        }
        if let blob = try db.run("SELECT json FROM manual_notes_revisions WHERE meeting_id=? ORDER BY created_at DESC, rowid DESC LIMIT 1",
                                 [.text(meeting.rawValue)]).first?["json"]?.blob {
            let n = try ContractCoding.decode(ManualNotesRevision.self, from: blob)
            try insert(.userNotes, n.id.rawValue, nil, n.markdown)
        }
    }

    /// Each speaker's shown name, with renames the user made since this revision was reconciled applied on top.
    static func speakerNames(_ speakers: [Speaker], _ edits: [UserEdit]) -> [SpeakerID: String] {
        var names = Dictionary(speakers.map { ($0.id, $0.shownName) }, uniquingKeysWith: { a, _ in a })
        for e in edits where e.conflict == .applied {
            if case .renameSpeaker(let id, let name) = e.operation, let sp = speakers.first(where: { $0.id == id }) { names[id] = name ?? sp.label }
        }
        return names
    }
}
