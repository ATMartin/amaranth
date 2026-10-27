import Foundation

/// Versioned migrations. Each entry runs once inside a transaction; `PRAGMA user_version` records progress.
/// Structured payloads (transcripts, summaries, edits) are stored as versioned JSON blobs keyed by stable IDs;
/// columns exist for what we query or join on. Audio and model files live outside the database.
enum Schema {
    static let migrations: [String] = [
        // v1: plan §9 required records.
        """
        CREATE TABLE meetings (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            created_at REAL NOT NULL,
            capture_state TEXT NOT NULL,
            selected_sources TEXT NOT NULL,
            audio TEXT NOT NULL,
            duration_ns INTEGER NOT NULL DEFAULT 0,
            current_transcript_revision TEXT,
            provisional_transcript_revision TEXT,
            current_summary_revision TEXT,
            deleted_at REAL,
            json BLOB NOT NULL
        );
        CREATE TABLE capture_epochs (
            id TEXT PRIMARY KEY,
            meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            source TEXT NOT NULL,
            idx INTEGER NOT NULL,
            session_start_ns INTEGER NOT NULL,
            json BLOB NOT NULL,
            UNIQUE (meeting_id, source, idx)
        );
        CREATE TABLE audio_segments (
            id TEXT PRIMARY KEY,
            meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            source TEXT NOT NULL,
            epoch_id TEXT NOT NULL,
            sequence INTEGER NOT NULL,
            start_ns INTEGER NOT NULL,
            end_ns INTEGER NOT NULL,
            frame_count INTEGER NOT NULL,
            relative_path TEXT NOT NULL,
            sha256 TEXT NOT NULL,
            state TEXT NOT NULL,
            json BLOB NOT NULL,
            UNIQUE (meeting_id, source, sequence)
        );
        CREATE INDEX audio_segments_by_time ON audio_segments (meeting_id, source, start_ns);
        CREATE TABLE capture_events (
            id TEXT PRIMARY KEY,
            meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            source TEXT,
            kind TEXT NOT NULL,
            start_ns INTEGER NOT NULL,
            end_ns INTEGER NOT NULL,
            json BLOB NOT NULL
        );
        CREATE INDEX capture_events_by_meeting ON capture_events (meeting_id, start_ns);
        CREATE TABLE processing_jobs (
            id TEXT PRIMARY KEY,
            meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            stage TEXT NOT NULL,
            input_hash TEXT NOT NULL,
            config_hash TEXT NOT NULL,
            state TEXT NOT NULL,
            lease_owner TEXT,
            lease_expires_at REAL,
            updated_at REAL NOT NULL,
            json BLOB NOT NULL,
            UNIQUE (meeting_id, stage, input_hash, config_hash)
        );
        CREATE TABLE transcript_revisions (
            id TEXT PRIMARY KEY,
            meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            kind TEXT NOT NULL,
            stage TEXT NOT NULL,
            created_at REAL NOT NULL,
            json BLOB NOT NULL
        );
        CREATE TABLE diarization_results (
            id TEXT PRIMARY KEY,
            meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            source TEXT NOT NULL,
            json BLOB NOT NULL
        );
        CREATE TABLE user_edits (
            id TEXT PRIMARY KEY,
            meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            sequence INTEGER NOT NULL,
            conflict TEXT NOT NULL,
            json BLOB NOT NULL,
            UNIQUE (meeting_id, sequence)
        );
        CREATE TABLE summary_revisions (
            id TEXT PRIMARY KEY,
            meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            transcript_revision TEXT NOT NULL,
            is_stale INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL,
            json BLOB NOT NULL
        );
        CREATE TABLE scratchpad_revisions (
            id TEXT PRIMARY KEY,
            meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            created_at REAL NOT NULL,
            json BLOB NOT NULL
        );
        CREATE TABLE manual_notes_revisions (
            id TEXT PRIMARY KEY,
            meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            created_at REAL NOT NULL,
            json BLOB NOT NULL
        );
        """,
        // v2 (T11): local full-text search over titles, current transcripts, generated notes and user notes. The private
        // scratchpad is not indexed. Rows are replaced whenever the indexed content changes and purged on deletion.
        """
        CREATE VIRTUAL TABLE search_index USING fts5(
            meeting_id UNINDEXED, kind UNINDEXED, ref UNINDEXED, start_ns UNINDEXED, text,
            tokenize='unicode61 remove_diacritics 2'
        );
        """,
        // v3 (T49): a meeting's linked calendar event, as a column so a future integration can find the meeting an event
        // already belongs to. People and the event itself live in the meeting JSON; older rows decode with neither.
        """
        ALTER TABLE meetings ADD COLUMN linked_event_id TEXT;
        CREATE INDEX meetings_by_linked_event ON meetings (linked_event_id);
        """,
        // v4 (T53): retrieval for “ask anything”. Transcript rows carry the speaker's shown name in their own column (so
        // “what did Rochelle say about the kitchen” matches her lines), and an unindexed `evidence` column with the row's
        // TranscriptEvidence refs (JSON) so passages cite the transcript without decoding it. Speaker names and meeting
        // people also get rows of their own (kinds `speaker`, `person`). MeetingStore.init rebuilds the index once.
        """
        DROP TABLE search_index;
        CREATE VIRTUAL TABLE search_index USING fts5(
            meeting_id UNINDEXED, kind UNINDEXED, ref UNINDEXED, start_ns UNINDEXED, text, speaker, evidence UNINDEXED,
            tokenize='unicode61 remove_diacritics 2'
        );
        """,
    ]

    /// Applies pending migrations; returns the version the database had before.
    @discardableResult
    static func migrate(_ db: SQLiteDB) throws -> Int {
        let current = Int(try db.run("PRAGMA user_version").first?["user_version"]?.int ?? 0)
        guard current <= migrations.count else {
            throw SQLiteDB.Error(code: -1, message: "database schema v\(current) is newer than this app (v\(migrations.count))")
        }
        for (i, sql) in migrations.enumerated() where i >= current {
            try db.transaction {
                try db.exec(sql)
                try db.exec("PRAGMA user_version = \(i + 1)")
            }
        }
        return current
    }
}
