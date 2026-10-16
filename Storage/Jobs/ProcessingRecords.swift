public import Foundation
public import Domain

/// Jobs, machine revisions and user edits (plan §9). All writes go through the store's single writer queue.
extension MeetingStore {
    // MARK: Jobs

    /// Inserts a job unless one with the same content key exists (idempotent enqueue). Returns the stored job.
    @discardableResult
    public func enqueue(_ newJob: ProcessingJob) throws -> ProcessingJob {
        if let existing = try job(forKey: newJob.key) { return existing }
        try upsertJob(newJob)
        return newJob
    }

    /// No-op for a deleted meeting: job rows are purged with it and must not be re-created by late updates.
    public func upsertJob(_ j: ProcessingJob) throws {
        try withDB { db in
            try db.transaction {
            guard try !Self.isTombstoned(db, j.key.meetingID) else { return }
            try db.run("""
                INSERT INTO processing_jobs (id, meeting_id, stage, input_hash, config_hash, state, lease_owner, lease_expires_at, updated_at, json)
                VALUES (?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET state=excluded.state, lease_owner=excluded.lease_owner,
                  lease_expires_at=excluded.lease_expires_at, updated_at=excluded.updated_at, json=excluded.json
                """, [.text(j.id.rawValue), .text(j.key.meetingID.rawValue), .text(j.key.stage.rawValue), .text(j.key.inputHash),
                      .text(j.key.configHash), .text(j.state.rawValue), j.lease.map { .text($0.owner) } ?? .null,
                      j.lease.map { .double($0.expiresAt.timeIntervalSince1970) } ?? .null, .double(j.updatedAt.timeIntervalSince1970),
                      .blob(try ContractCoding.encode(j))])
            }
        }
    }

    public func job(forKey k: JobKey) throws -> ProcessingJob? {
        try withDB { db in
            try db.run("SELECT json FROM processing_jobs WHERE meeting_id=? AND stage=? AND input_hash=? AND config_hash=?",
                       [.text(k.meetingID.rawValue), .text(k.stage.rawValue), .text(k.inputHash), .text(k.configHash)])
                .compactMap { $0["json"]?.blob }.map { try ContractCoding.decode(ProcessingJob.self, from: $0) }.first
        }
    }

    public func jobs(meeting: MeetingID? = nil, states: Set<ProcessingState>? = nil) throws -> [ProcessingJob] {
        let all: [ProcessingJob] = try withDB { db in
            let rows: [[String: SQLiteDB.Value]]
            if let meeting {
                rows = try db.run("SELECT json FROM processing_jobs WHERE meeting_id=? ORDER BY updated_at", [.text(meeting.rawValue)])
            } else {
                rows = try db.run("SELECT json FROM processing_jobs ORDER BY updated_at")
            }
            return try rows.compactMap { $0["json"]?.blob }.map { try ContractCoding.decode(ProcessingJob.self, from: $0) }
        }
        return states.map { s in all.filter { s.contains($0.state) } } ?? all
    }

    // MARK: Revisions

    public func insertTranscriptRevision(_ r: TranscriptRevision) throws {
        try withDB { db in
            try db.transaction {
            guard try !Self.isTombstoned(db, r.meetingID) else { return }
            try db.run("INSERT OR IGNORE INTO transcript_revisions (id, meeting_id, kind, stage, created_at, json) VALUES (?,?,?,?,?,?)",
                       [.text(r.id.rawValue), .text(r.meetingID.rawValue), .text(r.kind.rawValue), .text(r.stage.rawValue),
                        .double(r.createdAt.timeIntervalSince1970), .blob(try ContractCoding.encode(r))])
            }
        }
    }

    public func transcriptRevision(_ id: RevisionID) throws -> TranscriptRevision? {
        try withDB { db in
            try db.run("SELECT json FROM transcript_revisions WHERE id=?", [.text(id.rawValue)])
                .compactMap { $0["json"]?.blob }.map { try ContractCoding.decode(TranscriptRevision.self, from: $0) }.first
        }
    }

    public func transcriptRevisions(_ meeting: MeetingID) throws -> [TranscriptRevision] {
        try withDB { db in
            try db.run("SELECT json FROM transcript_revisions WHERE meeting_id=? ORDER BY created_at", [.text(meeting.rawValue)])
                .compactMap { $0["json"]?.blob }.map { try ContractCoding.decode(TranscriptRevision.self, from: $0) }
        }
    }

    public func insertDiarization(_ d: DiarizationResult) throws {
        try withDB { db in
            try db.transaction {
            guard try !Self.isTombstoned(db, d.meetingID) else { return }
            try db.run("INSERT OR IGNORE INTO diarization_results (id, meeting_id, source, json) VALUES (?,?,?,?)",
                       [.text(d.id.rawValue), .text(d.meetingID.rawValue), .text(d.source.rawValue), .blob(try ContractCoding.encode(d))])
            }
        }
    }

    public func diarization(_ id: RevisionID) throws -> DiarizationResult? {
        try withDB { db in
            try db.run("SELECT json FROM diarization_results WHERE id=?", [.text(id.rawValue)])
                .compactMap { $0["json"]?.blob }.map { try ContractCoding.decode(DiarizationResult.self, from: $0) }.first
        }
    }

    // MARK: Edits

    public func appendEdit(_ e: UserEdit) throws {
        try withDB { db in
            try db.transaction {
                guard try !Self.isTombstoned(db, e.meetingID) else { return }
                try db.run("INSERT OR REPLACE INTO user_edits (id, meeting_id, sequence, conflict, json) VALUES (?,?,?,?,?)",
                           [.text(e.id.rawValue), .text(e.meetingID.rawValue), .int(Int64(e.sequence)), .text(e.conflict.rawValue),
                            .blob(try ContractCoding.encode(e))])
                if case .correctText = e.operation { try Self.reindex(db, e.meetingID) }   // search reflects corrections
            }
        }
    }

    public func edits(_ meeting: MeetingID) throws -> [UserEdit] {
        try withDB { db in
            try db.run("SELECT json FROM user_edits WHERE meeting_id=? ORDER BY sequence", [.text(meeting.rawValue)])
                .compactMap { $0["json"]?.blob }.map { try ContractCoding.decode(UserEdit.self, from: $0) }
        }
    }

    /// Atomically publishes a machine revision as the meeting's current transcript — unless the meeting was deleted.
    /// Returns false (and publishes nothing) for tombstoned meetings, so late results cannot resurrect deleted content.
    @discardableResult
    public func publishTranscript(_ r: TranscriptRevision, provisional: Bool = false) throws -> Bool {
        try withDB { db in
            try db.transaction {
                guard let row = try db.run("SELECT json FROM meetings WHERE id=?", [.text(r.meetingID.rawValue)]).first?["json"]?.blob else { return false }
                var m = try ContractCoding.decode(Meeting.self, from: row)
                guard m.deletedAt == nil else { return false }
                try db.run("INSERT OR IGNORE INTO transcript_revisions (id, meeting_id, kind, stage, created_at, json) VALUES (?,?,?,?,?,?)",
                           [.text(r.id.rawValue), .text(r.meetingID.rawValue), .text(r.kind.rawValue), .text(r.stage.rawValue),
                            .double(r.createdAt.timeIntervalSince1970), .blob(try ContractCoding.encode(r))])
                if provisional { m.provisionalTranscriptRevisionID = r.id } else { m.currentTranscriptRevisionID = r.id }
                try db.run("UPDATE meetings SET current_transcript_revision=?, provisional_transcript_revision=?, json=? WHERE id=?",
                           [m.currentTranscriptRevisionID.map { .text($0.rawValue) } ?? .null,
                            m.provisionalTranscriptRevisionID.map { .text($0.rawValue) } ?? .null,
                            .blob(try ContractCoding.encode(m)), .text(m.id.rawValue)])
                if !provisional { try Self.reindex(db, m.id) }
                return true
            }
        }
    }

    /// Tombstones a meeting (deletion is a transaction: jobs are cancelled by the scheduler before inputs are removed).
    public func tombstone(_ id: MeetingID, at date: Date = Date()) throws {
        guard var m = try meeting(id) else { return }
        m.deletedAt = date
        try upsertMeeting(m)
    }
}
