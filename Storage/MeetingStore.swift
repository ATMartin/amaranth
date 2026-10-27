public import Foundation
public import Domain

/// Single controlled writer for the meeting database (plan §9). All access is serialized on one queue; callers on
/// realtime/audio threads must never call in directly — the capture path batches through `SegmentIndexer`.
public final class MeetingStore: @unchecked Sendable {
    public let root: URL
    private let db: SQLiteDB
    private let queue = DispatchQueue(label: "amaranth.storage.writer")

    /// `root` is the Amaranth data directory (Application Support/Amaranth); the DB lives at `root/amaranth.sqlite`.
    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(root.path, 0o700)   // also when the folder already existed with looser permissions
        db = try SQLiteDB(path: root.appending(path: "amaranth.sqlite").path)
        let previousVersion = try Schema.migrate(db)
        // Restrictive permissions (plan §11): meeting content is readable only by this user.
        for name in ["amaranth.sqlite", "amaranth.sqlite-wal", "amaranth.sqlite-shm"] {
            chmod(root.appending(path: name).path, 0o600)
        }
        for sub in ["meetings", "work"] {
            let dir = root.appending(path: sub)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            chmod(dir.path, 0o700)
        }
        // Databases created before search existed (v1), or before the v4 index layout (T53), get their index built once.
        if (1..<4).contains(previousVersion) { try rebuildSearchIndex() }
    }

    public static func defaultRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Amaranth")
    }

    public func meetingDirectory(_ id: MeetingID) -> URL { root.appending(path: "meetings/\(id.rawValue)") }

    private func sync<T>(_ body: () throws -> T) throws -> T { try queue.sync(execute: body) }
    /// Serialized access for extensions in this module.
    func withDB<T>(_ body: (SQLiteDB) throws -> T) throws -> T { try queue.sync { try body(db) } }
    private func json<T: Codable & Sendable>(_ v: T) throws -> SQLiteDB.Value { .blob(try ContractCoding.encode(v)) }
    private func decode<T: Codable & Sendable>(_ t: T.Type, _ rows: [[String: SQLiteDB.Value]]) throws -> [T] {
        try rows.compactMap { $0["json"]?.blob }.map { try ContractCoding.decode(t, from: $0) }
    }

    /// True once a meeting is tombstoned. Every write keyed by meeting checks this inside its own transaction, so a
    /// late result (or a recovery replay) can never re-create content for a deleted meeting.
    static func isTombstoned(_ db: SQLiteDB, _ id: MeetingID) throws -> Bool {
        try db.run("SELECT deleted_at FROM meetings WHERE id=?", [.text(id.rawValue)]).first.map { $0["deleted_at"]?.double != nil } ?? false
    }

    static func liveFilter(_ db: SQLiteDB) -> (MeetingID) throws -> Bool {
        var cache: [MeetingID: Bool] = [:]
        return { id in
            if let v = cache[id] { return v }
            let v = try !isTombstoned(db, id)
            cache[id] = v
            return v
        }
    }

    // MARK: Meetings

    /// Inserts or replaces a meeting. On an existing row its people and linked event are kept as stored: writers that
    /// hold an older copy (the recorder, recovery, rename) must not drop them. Change them with `setPeople` and
    /// `setLinkedEvent`.
    public func upsertMeeting(_ meeting: Meeting) throws {
        try sync {
            var m = meeting
            if let row = try db.run("SELECT json FROM meetings WHERE id=?", [.text(m.id.rawValue)]).first?["json"]?.blob {
                let stored = try ContractCoding.decode(Meeting.self, from: row)
                m.people = stored.people
                m.linkedEvent = stored.linkedEvent
            }
            try db.run("""
                INSERT INTO meetings (id, title, created_at, capture_state, selected_sources, audio, duration_ns,
                  current_transcript_revision, provisional_transcript_revision, current_summary_revision, deleted_at,
                  linked_event_id, json)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET title=excluded.title, capture_state=excluded.capture_state,
                  selected_sources=excluded.selected_sources, audio=excluded.audio, duration_ns=excluded.duration_ns,
                  current_transcript_revision=excluded.current_transcript_revision,
                  provisional_transcript_revision=excluded.provisional_transcript_revision,
                  current_summary_revision=excluded.current_summary_revision, deleted_at=excluded.deleted_at, json=excluded.json
                """, [.text(m.id.rawValue), .text(m.title), .double(m.createdAt.timeIntervalSince1970), .text(m.captureState.rawValue),
                      .text(m.selectedSources.rawValue), .text(m.audio.rawValue), .int(m.duration.nanoseconds),
                      m.currentTranscriptRevisionID.map { .text($0.rawValue) } ?? .null,
                      m.provisionalTranscriptRevisionID.map { .text($0.rawValue) } ?? .null,
                      m.currentSummaryRevisionID.map { .text($0.rawValue) } ?? .null,
                      m.deletedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                      m.linkedEvent.map { .text($0.identifier) } ?? .null, try json(m)])
            // Keep the title searchable; a tombstoned meeting leaves the index entirely.
            if m.deletedAt != nil {
                try db.run("DELETE FROM search_index WHERE meeting_id=?", [.text(m.id.rawValue)])
            } else {
                try db.run("DELETE FROM search_index WHERE meeting_id=? AND kind='title'", [.text(m.id.rawValue)])
                try db.run("INSERT INTO search_index (meeting_id, kind, ref, start_ns, text) VALUES (?,?,?,NULL,?)",
                           [.text(m.id.rawValue), .text("title"), .text(m.id.rawValue), .text(m.title)])
            }
        }
    }

    /// Replaces the meeting's people (T49). Names are trimmed; empty names and repeats (ignoring case) are dropped,
    /// keeping the first. No-op for a missing or deleted meeting.
    public func setPeople(_ people: [Person], for id: MeetingID) throws {
        var seen = Set<String>()
        let cleaned = people.compactMap { p -> Person? in
            let name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { return nil }
            return Person(name: name, source: p.source, email: p.email)
        }
        try updateMetadata(id) { $0.people = cleaned }
        try withDB { db in try db.transaction { try Self.reindex(db, id) } }   // people are searchable (T53)
    }

    /// Links the meeting to a calendar event, or unlinks it with nil (T49). No-op for a missing or deleted meeting.
    public func setLinkedEvent(_ event: LinkedEvent?, for id: MeetingID) throws {
        try updateMetadata(id) { $0.linkedEvent = event }
    }

    /// Links an event and merges its attendees in one write (T58): `merge` gets the stored people and returns the new
    /// list, so a concurrent people edit can't be lost between reading and writing.
    public func linkEvent(_ event: LinkedEvent, for id: MeetingID, mergingPeople merge: ([Person]) -> [Person]) throws {
        try updateMetadata(id) { m in
            m.linkedEvent = event
            var seen = Set<String>()
            m.people = merge(m.people).compactMap { p in
                let name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { return nil }
                return Person(name: name, source: p.source, email: p.email)
            }
        }
        try withDB { db in try db.transaction { try Self.reindex(db, id) } }   // people are searchable (T53)
    }

    /// Live meetings linked to the calendar event `identifier` (T57, via the `linked_event_id` index). Recurring
    /// occurrences share an identifier; callers compare `linkedEvent.start` to tell them apart.
    public func meetings(linkedTo identifier: String) throws -> [Meeting] {
        try sync {
            try decode(Meeting.self, db.run("SELECT json FROM meetings WHERE linked_event_id = ? AND deleted_at IS NULL ORDER BY created_at DESC",
                                            [.text(identifier)]))
        }
    }

    private func updateMetadata(_ id: MeetingID, _ change: (inout Meeting) -> Void) throws {
        try sync {
            try db.transaction {
                guard let row = try db.run("SELECT json FROM meetings WHERE id=?", [.text(id.rawValue)]).first?["json"]?.blob else { return }
                var m = try ContractCoding.decode(Meeting.self, from: row)
                guard m.deletedAt == nil else { return }
                change(&m)
                try db.run("UPDATE meetings SET linked_event_id=?, json=? WHERE id=?",
                           [m.linkedEvent.map { .text($0.identifier) } ?? .null, try json(m), .text(id.rawValue)])
            }
        }
    }

    public func meeting(_ id: MeetingID) throws -> Meeting? {
        try sync { try decode(Meeting.self, db.run("SELECT json FROM meetings WHERE id = ?", [.text(id.rawValue)])).first }
    }

    public func meetings(includeDeleted: Bool = false) throws -> [Meeting] {
        try sync {
            try decode(Meeting.self, db.run("SELECT json FROM meetings \(includeDeleted ? "" : "WHERE deleted_at IS NULL") ORDER BY created_at DESC"))
        }
    }

    // MARK: Capture records (idempotent; replays from recovery are harmless)

    public func insertEpochs(_ epochs: [CaptureEpoch]) throws {
        guard !epochs.isEmpty else { return }
        try sync {
            try db.transaction {
                let live = Self.liveFilter(db)
                for e in epochs where try live(e.meetingID) {
                    try db.run("INSERT OR IGNORE INTO capture_epochs (id, meeting_id, source, idx, session_start_ns, json) VALUES (?,?,?,?,?,?)",
                               [.text(e.id.rawValue), .text(e.meetingID.rawValue), .text(e.source.rawValue), .int(Int64(e.index)),
                                .int(e.sessionStart.nanoseconds), try json(e)])
                }
            }
        }
    }

    /// Only committed segments are indexed; a row never points at an uncommitted file.
    public func insertSegments(_ segments: [AudioSegmentRecord]) throws {
        guard !segments.isEmpty else { return }
        precondition(segments.allSatisfy { $0.state == .committed }, "only committed segments are indexed")
        try sync {
            try db.transaction {
                let live = Self.liveFilter(db)
                for s in segments where try live(s.meetingID) {
                    try db.run("""
                        INSERT OR IGNORE INTO audio_segments (id, meeting_id, source, epoch_id, sequence, start_ns, end_ns, frame_count,
                          relative_path, sha256, state, json) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                        """, [.text(s.id.rawValue), .text(s.meetingID.rawValue), .text(s.source.rawValue), .text(s.epochID.rawValue),
                              .int(s.sequence), .int(s.interval.start.nanoseconds), .int(s.interval.end.nanoseconds), .int(s.frameCount),
                              .text(s.relativePath), .text(s.sha256), .text(s.state.rawValue), try json(s)])
                }
            }
        }
    }

    public func insertEvents(_ events: [CaptureEvent]) throws {
        guard !events.isEmpty else { return }
        try sync {
            try db.transaction {
                let live = Self.liveFilter(db)
                for e in events where try live(e.meetingID) {
                    try db.run("INSERT OR IGNORE INTO capture_events (id, meeting_id, source, kind, start_ns, end_ns, json) VALUES (?,?,?,?,?,?,?)",
                               [.text(e.id.rawValue), .text(e.meetingID.rawValue), e.source.map { .text($0.rawValue) } ?? .null,
                                .text(e.kind.rawValue), .int(e.interval.start.nanoseconds), .int(e.interval.end.nanoseconds), try json(e)])
                }
            }
        }
    }

    public func segments(_ meeting: MeetingID, source: SourceKind? = nil) throws -> [AudioSegmentRecord] {
        try sync {
            if let source {
                return try decode(AudioSegmentRecord.self, db.run(
                    "SELECT json FROM audio_segments WHERE meeting_id = ? AND source = ? ORDER BY sequence", [.text(meeting.rawValue), .text(source.rawValue)]))
            }
            return try decode(AudioSegmentRecord.self, db.run(
                "SELECT json FROM audio_segments WHERE meeting_id = ? ORDER BY source, sequence", [.text(meeting.rawValue)]))
        }
    }

    public func epochs(_ meeting: MeetingID) throws -> [CaptureEpoch] {
        try sync { try decode(CaptureEpoch.self, db.run("SELECT json FROM capture_epochs WHERE meeting_id = ? ORDER BY source, idx", [.text(meeting.rawValue)])) }
    }

    public func events(_ meeting: MeetingID) throws -> [CaptureEvent] {
        try sync { try decode(CaptureEvent.self, db.run("SELECT json FROM capture_events WHERE meeting_id = ? ORDER BY start_ns", [.text(meeting.rawValue)])) }
    }

    /// Integrity check used by tests and diagnostics.
    func integrityOK() throws -> Bool {
        try sync { try db.run("PRAGMA integrity_check").first?["integrity_check"]?.text == "ok" }
    }
}

/// Batches capture records into the store off the audio path (≤ 1 s latency), so index writes never block the writer.
public final class SegmentIndexer: @unchecked Sendable {
    private let store: MeetingStore
    private let lock = NSLock()
    private var segments: [AudioSegmentRecord] = []
    private var epochs: [CaptureEpoch] = []
    private var events: [CaptureEvent] = []
    private let queue = DispatchQueue(label: "amaranth.storage.indexer")
    private var timer: (any DispatchSourceTimer)?
    public private(set) var lastError: (any Error)?

    public init(store: MeetingStore, interval: TimeInterval = 1.0) {
        self.store = store
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in self?.flush() }
        t.resume()
        timer = t
    }

    deinit { timer?.cancel() }

    public func add(_ s: AudioSegmentRecord) { lock.withLock { segments.append(s) } }
    public func add(_ e: CaptureEpoch) { lock.withLock { epochs.append(e) } }
    public func add(_ e: CaptureEvent) { lock.withLock { events.append(e) } }

    /// Writes everything pending (epochs first so segments can reference them). Safe to call from any thread.
    public func flush() {
        let (s, ep, ev) = lock.withLock { () -> ([AudioSegmentRecord], [CaptureEpoch], [CaptureEvent]) in
            defer { segments = []; epochs = []; events = [] }
            return (segments, epochs, events)
        }
        do {
            try store.insertEpochs(ep)
            try store.insertSegments(s)
            try store.insertEvents(ev)
        } catch {
            // Rows are reconstructable from the self-describing files and journal; keep them for the next attempt.
            lock.withLock { segments += s; epochs += ep; events += ev; lastError = error }
        }
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        queue.sync { flush() }
    }
}
