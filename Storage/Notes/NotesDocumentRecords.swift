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
}
