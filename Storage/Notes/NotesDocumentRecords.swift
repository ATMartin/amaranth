public import Foundation
public import Domain

/// The meeting's notes document (spec 0008): immutable revisions, newest current. Every save is a new revision, so
/// Previous Versions can restore any of them and generation can tell whether the notes changed since its snapshot.
extension MeetingStore {
    /// Saves `d` as the meeting's newest notes revision and reindexes it. Returns false for a deleted meeting (a late save
    /// cannot re-create its content).
    @discardableResult
    public func saveNotesDocument(_ d: NotesDocumentRevision) throws -> Bool {
        try withDB { db in
            try db.transaction {
                guard try db.run("SELECT 1 FROM meetings WHERE id=?", [.text(d.meetingID.rawValue)]).first != nil,
                      try !Self.isTombstoned(db, d.meetingID) else { return false }
                try Self.insertNotesDocument(db, d)
                try Self.reindex(db, d.meetingID)
                return true
            }
        }
    }

    static func insertNotesDocument(_ db: SQLiteDB, _ d: NotesDocumentRevision) throws {
        try db.run("INSERT INTO notes_document_revisions (id, meeting_id, created_at, json) VALUES (?,?,?,?)",
                   [.text(d.id.rawValue), .text(d.meetingID.rawValue), .double(d.createdAt.timeIntervalSince1970), .blob(try ContractCoding.encode(d))])
    }

    static func currentNotesDocument(_ db: SQLiteDB, _ meeting: MeetingID) throws -> NotesDocumentRevision? {
        try db.run("SELECT json FROM notes_document_revisions WHERE meeting_id=? ORDER BY rowid DESC LIMIT 1", [.text(meeting.rawValue)])
            .compactMap { $0["json"]?.blob }.map { try ContractCoding.decode(NotesDocumentRevision.self, from: $0) }.first
    }

    public func currentNotesDocument(_ meeting: MeetingID) throws -> NotesDocumentRevision? {
        try withDB { db in try Self.currentNotesDocument(db, meeting) }
    }

    public func notesDocumentRevision(_ id: RevisionID) throws -> NotesDocumentRevision? {
        try withDB { db in
            try db.run("SELECT json FROM notes_document_revisions WHERE id=?", [.text(id.rawValue)])
                .compactMap { $0["json"]?.blob }.map { try ContractCoding.decode(NotesDocumentRevision.self, from: $0) }.first
        }
    }

    /// Newest first. Revisions are append-only, so insertion order is their order (stored times are rounded to the second).
    public func notesDocumentRevisions(_ meeting: MeetingID, limit: Int = 50) throws -> [NotesDocumentRevision] {
        try withDB { db in
            try db.run("SELECT json FROM notes_document_revisions WHERE meeting_id=? ORDER BY rowid DESC LIMIT ?",
                       [.text(meeting.rawValue), .int(Int64(limit))])
                .compactMap { $0["json"]?.blob }.map { try ContractCoding.decode(NotesDocumentRevision.self, from: $0) }
        }
    }

    /// Library v5 → v6 (spec 0008 §8), inside the schema migration's transaction. Every meeting that is not deleted gets
    /// one notes document: its current generated notes, then "Your notes", then the scratchpad if it was used for notes.
    /// Scratchpad text that was never used for notes is deleted (user decision 2026-10-31): it was promised private and has
    /// no place in notes. Only the revision that was used stays, readable until the meeting is deleted. Deleted meetings keep nothing (their rows were purged).
    static func migrateToNotesDocuments(_ db: SQLiteDB) throws {
        let now = Date()
        for row in try db.run("SELECT id, json FROM meetings WHERE deleted_at IS NULL") {
            guard let raw = row["id"]?.text, let blob = row["json"]?.blob else { continue }
            let id = MeetingID(raw)
            let m = try ContractCoding.decode(Meeting.self, from: blob)
            func latest<T: Codable & Sendable>(_ t: T.Type, _ table: String) throws -> T? {
                try db.run("SELECT json FROM \(table) WHERE meeting_id=? ORDER BY created_at DESC, rowid DESC LIMIT 1", [.text(raw)])
                    .compactMap { $0["json"]?.blob }.map { try ContractCoding.decode(t, from: $0) }.first
            }
            let summary = try m.currentSummaryRevisionID.flatMap { sid in
                try db.run("SELECT json FROM summary_revisions WHERE id=?", [.text(sid.rawValue)])
                    .compactMap { $0["json"]?.blob }.map { try ContractCoding.decode(SummaryRevision.self, from: $0) }.first
            }
            let manual = try latest(ManualNotesRevision.self, "manual_notes_revisions")
            // Used for notes: switched on now, or cited by the current notes (that revision's text).
            var included: ScratchpadRevision?
            if let pad = try latest(ScratchpadRevision.self, "scratchpad_revisions"), pad.includeInSummary {
                included = pad
            } else if let s = summary, s.influencedByPersonalNotes, let pid = s.scratchpadRevisionID {
                included = try db.run("SELECT json FROM scratchpad_revisions WHERE id=?", [.text(pid.rawValue)])
                    .compactMap { $0["json"]?.blob }.map { try ContractCoding.decode(ScratchpadRevision.self, from: $0) }.first
            }
            // Only the revision that was used survives; earlier or later private text was never included.
            try db.run("DELETE FROM scratchpad_revisions WHERE meeting_id=? AND id IS NOT ?", [.text(raw), included.map { .text($0.id.rawValue) } ?? .null])
            guard try currentNotesDocument(db, id) == nil else { continue }
            try insertNotesDocument(db, NotesComposer.migrated(meetingID: id, summary: summary, manualNotes: manual,
                                                               includedScratchpad: included, createdAt: now))
        }
    }
}
