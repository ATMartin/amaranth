public import Foundation
public import Domain

/// Library v5 → v6 (T89, spec 0008 §8): "Your notes" and the private scratchpad become the notes document. Their v5
/// records exist only here: the step reads them, and deletion purges their tables (Deletion.swift). Nothing else in the
/// app reads or writes them.
extension MeetingStore {
    /// A v5 private scratchpad revision, as stored (JSON in `scratchpad_revisions`).
    struct V5Scratchpad: Codable, Sendable {
        var id: RevisionID
        var meetingID: MeetingID
        var text: String
        var includeInSummary: Bool
        var createdAt: Date
    }

    /// A v5 "Your notes" revision, as stored (JSON in `manual_notes_revisions`).
    struct V5ManualNotes: Codable, Sendable {
        var id: RevisionID
        var meetingID: MeetingID
        var basedOnSummaryRevisionID: RevisionID?
        var markdown: String
        var createdAt: Date
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
            let manual = try latest(V5ManualNotes.self, "manual_notes_revisions")
            // Used for notes: switched on now, or cited by the current notes (that revision's text).
            var included: V5Scratchpad?
            if let pad = try latest(V5Scratchpad.self, "scratchpad_revisions"), pad.includeInSummary {
                included = pad
            } else if let s = summary, s.influencedByPersonalNotes, let pid = s.scratchpadRevisionID {
                included = try db.run("SELECT json FROM scratchpad_revisions WHERE id=?", [.text(pid.rawValue)])
                    .compactMap { $0["json"]?.blob }.map { try ContractCoding.decode(V5Scratchpad.self, from: $0) }.first
            }
            // Only the revision that was used survives; earlier or later private text was never included.
            try db.run("DELETE FROM scratchpad_revisions WHERE meeting_id=? AND id IS NOT ?", [.text(raw), included.map { .text($0.id.rawValue) } ?? .null])
            guard try currentNotesDocument(db, id) == nil else { continue }
            try insertNotesDocument(db, migratedDocument(meetingID: id, summary: summary, manualNotes: manual, includedScratchpad: included, createdAt: now))
        }
    }

    /// A meeting's first notes document: its generated notes as model blocks (transcript evidence kept, scratchpad
    /// citations and the "used your personal notes" limitation dropped), then "Your notes", then the scratchpad text that
    /// was used for generation (`includedScratchpad`; nil when it never was).
    static func migratedDocument(meetingID: MeetingID, summary: SummaryRevision?, manualNotes: V5ManualNotes?,
                                 includedScratchpad: V5Scratchpad?, createdAt: Date) -> NotesDocumentRevision {
        let user = NotesComposer.userBlocks(fromText: manualNotes?.markdown ?? "") + NotesComposer.userBlocks(fromText: includedScratchpad?.text ?? "")
        return NotesComposer.compose(summary: summary?.withoutScratchpadReferences, userBlocks: user, meetingID: meetingID, createdAt: createdAt,
                                     origin: .migrated)
    }
}
