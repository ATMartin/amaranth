import Foundation
public import Domain

/// Everything one meeting's external read model is built from (spec 0009 §1), read in one pass on the store's single
/// queue so a concurrent edit can't land between two of the reads: the result is one consistent state of the meeting.
/// These are the stored records; `MeetingAccess` turns them into what the user sees and never serializes them as is.
public struct MeetingSourceRecords: Sendable {
    public var meeting: Meeting
    /// The meeting's folder (nil when unfiled).
    public var folder: Folder?
    /// The machine revision the app shows: the final one, else the live (provisional) one. Edits are NOT applied.
    public var transcript: TranscriptRevision?
    public var edits: [UserEdit]
    /// The current notes document (spec 0008).
    public var notes: NotesDocumentRevision?
    /// The generated notes the current document was composed from, with `isStale` computed at read time (nil when the
    /// document has none). Only provenance leaves the app: its body is the original model output.
    public var notesSummary: SummaryRevision?
    /// True when a newer generation result waits for Replace/Dismiss (spec 0008 §4).
    public var hasPendingNotes: Bool
    public var jobs: [ProcessingJob]
    public var events: [CaptureEvent]

    public init(meeting: Meeting, folder: Folder? = nil, transcript: TranscriptRevision? = nil, edits: [UserEdit] = [],
                notes: NotesDocumentRevision? = nil, notesSummary: SummaryRevision? = nil, hasPendingNotes: Bool = false,
                jobs: [ProcessingJob] = [], events: [CaptureEvent] = []) {
        self.meeting = meeting; self.folder = folder; self.transcript = transcript; self.edits = edits; self.notes = notes
        self.notesSummary = notesSummary; self.hasPendingNotes = hasPendingNotes; self.jobs = jobs; self.events = events
    }
}

extension MeetingStore {
    /// The records of a live meeting, read consistently; nil for a missing or deleted meeting.
    public func readMeetingSource(_ id: MeetingID) throws -> MeetingSourceRecords? {
        try withDB { db in
            guard let blob = try db.run("SELECT json FROM meetings WHERE id=?", [.text(id.rawValue)]).first?["json"]?.blob else { return nil }
            let m = try ContractCoding.decode(Meeting.self, from: blob)
            guard m.deletedAt == nil else { return nil }
            func one<T: Codable & Sendable>(_ t: T.Type, _ sql: String, _ key: String) throws -> T? {
                try db.run(sql, [.text(key)]).compactMap { $0["json"]?.blob }.map { try ContractCoding.decode(t, from: $0) }.first
            }
            func all<T: Codable & Sendable>(_ t: T.Type, _ sql: String) throws -> [T] {
                try db.run(sql, [.text(id.rawValue)]).compactMap { $0["json"]?.blob }.map { try ContractCoding.decode(t, from: $0) }
            }
            let folder = try m.folderID.flatMap { try one(Folder.self, "SELECT json FROM folders WHERE id=?", $0.rawValue) }
            let transcript = try (m.currentTranscriptRevisionID ?? m.provisionalTranscriptRevisionID)
                .flatMap { try one(TranscriptRevision.self, "SELECT json FROM transcript_revisions WHERE id=?", $0.rawValue) }
            let edits = try all(UserEdit.self, "SELECT json FROM user_edits WHERE meeting_id=? ORDER BY sequence")
            let notes = try Self.currentNotesDocument(db, id)
            let latestEdit = edits.map(\.sequence).max() ?? 0
            var summary = try notes?.basedOnSummaryRevisionID.flatMap { try one(SummaryRevision.self, "SELECT json FROM summary_revisions WHERE id=?", $0.rawValue) }
            if let s = summary { summary?.isStale = m.currentTranscriptRevisionID != s.transcriptRevisionID || latestEdit > s.editSequence }
            let pending = m.currentSummaryRevisionID != nil && notes?.basedOnSummaryRevisionID != m.currentSummaryRevisionID
            return MeetingSourceRecords(meeting: m, folder: folder, transcript: transcript, edits: edits, notes: notes, notesSummary: summary,
                                        hasPendingNotes: pending,
                                        jobs: try all(ProcessingJob.self, "SELECT json FROM processing_jobs WHERE meeting_id=? ORDER BY updated_at"),
                                        events: try all(CaptureEvent.self, "SELECT json FROM capture_events WHERE meeting_id=? ORDER BY start_ns"))
        }
    }

    /// The content generation (spec 0009 §2): changes with every write that changes meeting content or scope.
    public func contentGeneration() throws -> String { try withDB { db in "\(db.instance)-\(db.contentGeneration)" } }

    /// One row per live meeting for listing and scope checks: metadata, folder name, whether it has notes, and the
    /// state of its latest processing jobs, with the content generation, all from one pass. No transcript is decoded.
    public func meetingCatalog() throws -> (generation: String, entries: [MeetingCatalogEntry]) {
        try withDB { db in
            var folders: [String: String] = [:]
            for r in try db.run("SELECT id, name FROM folders") { if let id = r["id"]?.text { folders[id] = r["name"]?.text } }
            let withNotes = Set(try db.run("SELECT DISTINCT meeting_id FROM notes_document_revisions").compactMap { $0["meeting_id"]?.text })
            var jobs: [String: [ProcessingStage: (Double, ProcessingState)]] = [:]
            for r in try db.run("SELECT meeting_id, stage, state, updated_at FROM processing_jobs") {
                guard let m = r["meeting_id"]?.text, let st = r["stage"]?.text.flatMap(ProcessingStage.init(rawValue:)),
                      let s = r["state"]?.text.flatMap(ProcessingState.init(rawValue:)) else { continue }
                let at = r["updated_at"]?.double ?? 0
                if let cur = jobs[m]?[st], cur.0 > at { continue }
                jobs[m, default: [:]][st] = (at, s)
            }
            let entries = try db.run("SELECT id, json FROM meetings WHERE deleted_at IS NULL").compactMap { r -> MeetingCatalogEntry? in
                guard let id = r["id"]?.text, let blob = r["json"]?.blob else { return nil }
                let m = try ContractCoding.decode(Meeting.self, from: blob)
                return MeetingCatalogEntry(meeting: m, folderName: m.folderID.flatMap { folders[$0.rawValue] }, hasNotesDocument: withNotes.contains(id),
                                           jobStates: (jobs[id] ?? [:]).mapValues(\.1))
            }
            return ("\(db.instance)-\(db.contentGeneration)", entries)
        }
    }

    /// IDs of live meetings, newest first (what an external listing may page through).
    public func liveMeetingIDs() throws -> [MeetingID] {
        try withDB { db in
            try db.run("SELECT id FROM meetings WHERE deleted_at IS NULL ORDER BY created_at DESC, id").compactMap { $0["id"]?.text }.map(MeetingID.init)
        }
    }

    /// This library's identity for external references (spec 0009 §1): a random UUID kept in `library-id` next to the
    /// database, made on first use. Not a secret, and not derived from anything on the Mac. Reading it never migrates.
    public func libraryID() throws -> String {
        try withDB { _ in
            let url = root.appending(path: "library-id")
            if let s = try? String(contentsOf: url, encoding: .utf8), let id = UUID(uuidString: s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return id.uuidString.lowercased()
            }
            let id = UUID().uuidString.lowercased()
            try Data((id + "\n").utf8).write(to: url, options: .atomic)
            chmod(url.path, 0o600)
            return id
        }
    }
}

/// A live meeting as listing sees it (spec 0009 §2).
public struct MeetingCatalogEntry: Sendable {
    public var meeting: Meeting
    public var folderName: String?
    public var hasNotesDocument: Bool
    /// The latest job's state per stage.
    public var jobStates: [ProcessingStage: ProcessingState]
}
