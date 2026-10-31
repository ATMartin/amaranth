public import Foundation
public import Domain

/// Generated notes, the private scratchpad, and user-authored notes. Generated revisions are immutable and published
/// atomically; a failed regeneration never replaces a usable summary, and user notes are separate records that
/// regeneration never touches.
extension MeetingStore {
    /// Publishes `s` as the meeting's current summary unless the meeting was deleted (late results cannot resurrect it).
    /// Spec 0008 §3–4: if the notes document is still the snapshot generation read (`s.notesRevisionID`, or the same
    /// blocks), a new document is composed from `s` and the user's lines. If the user changed the notes meanwhile, the
    /// document is left alone and `s` waits as the meeting's pending notes (`pendingNotes`) for Replace or Dismiss.
    @discardableResult
    public func publishSummary(_ s: SummaryRevision) throws -> Bool {
        try withDB { db in
            try db.transaction {
                guard let row = try db.run("SELECT json FROM meetings WHERE id=?", [.text(s.meetingID.rawValue)]).first?["json"]?.blob else { return false }
                var m = try ContractCoding.decode(Meeting.self, from: row)
                guard m.deletedAt == nil else { return false }
                try db.run("INSERT OR IGNORE INTO summary_revisions (id, meeting_id, transcript_revision, is_stale, created_at, json) VALUES (?,?,?,?,?,?)",
                           [.text(s.id.rawValue), .text(s.meetingID.rawValue), .text(s.transcriptRevisionID.rawValue), .int(0),
                            .double(s.createdAt.timeIntervalSince1970), .blob(try ContractCoding.encode(s))])
                m.currentSummaryRevisionID = s.id
                try db.run("UPDATE meetings SET current_summary_revision=?, json=? WHERE id=?",
                           [.text(s.id.rawValue), .blob(try ContractCoding.encode(m)), .text(m.id.rawValue)])
                let current = try Self.currentNotesDocument(db, s.meetingID)
                var unchanged = current?.id == s.notesRevisionID
                if !unchanged, let current, let sid = s.notesRevisionID,
                   let snapshot = try db.run("SELECT json FROM notes_document_revisions WHERE id=?", [.text(sid.rawValue)]).first?["json"]?.blob {
                    unchanged = current.hasSameContent(as: try ContractCoding.decode(NotesDocumentRevision.self, from: snapshot))
                }
                if unchanged {
                    try Self.insertNotesDocument(db, NotesComposer.compose(summary: s, userBlocks: current?.userBlocks ?? [], meetingID: s.meetingID, createdAt: Date()))
                }
                try Self.reindex(db, m.id)
                return true
            }
        }
    }

    public func summaryRevision(_ id: RevisionID) throws -> SummaryRevision? {
        try withDB { db in
            try db.run("SELECT json FROM summary_revisions WHERE id=?", [.text(id.rawValue)])
                .compactMap { $0["json"]?.blob }.map { try ContractCoding.decode(SummaryRevision.self, from: $0) }.first
        }
    }

    public func summaryRevisions(_ meeting: MeetingID) throws -> [SummaryRevision] {
        try withDB { db in
            try db.run("SELECT json FROM summary_revisions WHERE meeting_id=? ORDER BY created_at", [.text(meeting.rawValue)])
                .compactMap { $0["json"]?.blob }.map { try ContractCoding.decode(SummaryRevision.self, from: $0) }
        }
    }

    /// The current summary with `isStale` computed now: stale when the meeting's current transcript is a different
    /// revision or user edits (text, speakers) newer than the summary's input exist. Typing in the notes does not make
    /// them stale: those lines are the user's and survive any regeneration.
    public func currentSummary(_ meeting: MeetingID) throws -> SummaryRevision? {
        guard let m = try self.meeting(meeting), let id = m.currentSummaryRevisionID, var s = try summaryRevision(id) else { return nil }
        let latestEdit = try edits(meeting).map(\.sequence).max() ?? 0
        s.isStale = m.currentTranscriptRevisionID != s.transcriptRevisionID || latestEdit > s.editSequence
        return s
    }

    /// Generated notes held back because the user changed the notes while they were generated (spec 0008 §4): the current
    /// summary when the current document was not composed from it.
    public func pendingNotes(_ meeting: MeetingID) throws -> SummaryRevision? {
        guard let s = try currentSummary(meeting), let d = try currentNotesDocument(meeting), d.basedOnSummaryRevisionID != s.id else { return nil }
        return s
    }

    /// Replace: composes the pending notes with the *current* user lines (lines typed after the snapshot land under Also
    /// noted). The replaced document stays in Previous Versions.
    @discardableResult
    public func replaceWithPendingNotes(_ meeting: MeetingID) throws -> NotesDocumentRevision? {
        guard let s = try pendingNotes(meeting) else { return nil }
        let doc = NotesComposer.compose(summary: s, userBlocks: try currentNotesDocument(meeting)?.userBlocks ?? [], meetingID: meeting, createdAt: Date())
        return try saveNotesDocument(doc) ? doc : nil
    }

    /// Dismiss: keeps the notes as they are and records that the pending result was seen (a copy based on it).
    public func dismissPendingNotes(_ meeting: MeetingID) throws {
        guard let s = try pendingNotes(meeting), var d = try currentNotesDocument(meeting) else { return }
        d.id = RevisionID(); d.createdAt = Date(); d.basedOnSummaryRevisionID = s.id; d.origin = .edited
        try saveNotesDocument(d)
    }

    // MARK: Scratchpad (private; excluded from summaries, exports and search unless explicitly included)
    // Each save must be a new revision (new ID): summaries cite scratchpad text by revision and offset.

    public func saveScratchpad(_ s: ScratchpadRevision) throws {
        try withDB { db in
            try db.transaction {
            guard try !Self.isTombstoned(db, s.meetingID) else { return }
            try db.run("INSERT OR REPLACE INTO scratchpad_revisions (id, meeting_id, created_at, json) VALUES (?,?,?,?)",
                       [.text(s.id.rawValue), .text(s.meetingID.rawValue), .double(s.createdAt.timeIntervalSince1970), .blob(try ContractCoding.encode(s))])
            }
        }
    }

    public func scratchpadRevision(_ id: RevisionID) throws -> ScratchpadRevision? {
        try withDB { db in
            try db.run("SELECT json FROM scratchpad_revisions WHERE id=?", [.text(id.rawValue)])
                .compactMap { $0["json"]?.blob }.map { try ContractCoding.decode(ScratchpadRevision.self, from: $0) }.first
        }
    }

    public func latestScratchpad(_ meeting: MeetingID) throws -> ScratchpadRevision? {
        try withDB { db in
            try db.run("SELECT json FROM scratchpad_revisions WHERE meeting_id=? ORDER BY created_at DESC, rowid DESC LIMIT 1", [.text(meeting.rawValue)])
                .compactMap { $0["json"]?.blob }.map { try ContractCoding.decode(ScratchpadRevision.self, from: $0) }.first
        }
    }

    // MARK: User-authored notes

    public func saveManualNotes(_ n: ManualNotesRevision) throws {
        try withDB { db in
            try db.transaction {
                guard try !Self.isTombstoned(db, n.meetingID) else { return }
                try db.run("INSERT OR REPLACE INTO manual_notes_revisions (id, meeting_id, created_at, json) VALUES (?,?,?,?)",
                           [.text(n.id.rawValue), .text(n.meetingID.rawValue), .double(n.createdAt.timeIntervalSince1970), .blob(try ContractCoding.encode(n))])
                try Self.reindex(db, n.meetingID)
            }
        }
    }

    public func latestManualNotes(_ meeting: MeetingID) throws -> ManualNotesRevision? {
        try withDB { db in
            try db.run("SELECT json FROM manual_notes_revisions WHERE meeting_id=? ORDER BY created_at DESC, rowid DESC LIMIT 1", [.text(meeting.rawValue)])
                .compactMap { $0["json"]?.blob }.map { try ContractCoding.decode(ManualNotesRevision.self, from: $0) }.first
        }
    }
}
