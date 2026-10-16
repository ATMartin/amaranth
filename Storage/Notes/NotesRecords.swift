public import Foundation
public import Domain

/// Generated notes, the private scratchpad, and user-authored notes. Generated revisions are immutable and published
/// atomically; a failed regeneration never replaces a usable summary, and user notes are separate records that
/// regeneration never touches.
extension MeetingStore {
    /// Publishes `s` as the meeting's current summary unless the meeting was deleted (late results cannot resurrect it).
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
    /// revision, user edits newer than the summary's input exist, or the included personal notes changed.
    public func currentSummary(_ meeting: MeetingID) throws -> SummaryRevision? {
        guard let m = try self.meeting(meeting), let id = m.currentSummaryRevisionID, var s = try summaryRevision(id) else { return nil }
        let latestEdit = try edits(meeting).map(\.sequence).max() ?? 0
        // Personal notes changed since generation: newly included, edited while included, or switched off.
        let pad = try latestScratchpad(meeting)
        let padStale = (pad?.includeInSummary == true && pad?.id != s.scratchpadRevisionID) || (s.influencedByPersonalNotes && pad?.includeInSummary != true)
        s.isStale = m.currentTranscriptRevisionID != s.transcriptRevisionID || latestEdit > s.editSequence || padStale
        return s
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
