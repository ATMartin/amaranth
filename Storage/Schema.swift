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
        // v5 (T39): single-level folders. A meeting's folder is a column (for the sidebar's filter and counts) mirrored in
        // its JSON like the linked event; deleting a folder unfiles its meetings and never touches anything else. Names
        // are unique ignoring case (the store also compares with Unicode case folding; NOCASE only folds ASCII). No foreign
        // key on folder_id: the store keeps it valid (deleteFolder unfiles, moves and new rows check the folder exists).
        """
        CREATE TABLE folders (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            created_at REAL NOT NULL,
            sort_order INTEGER NOT NULL DEFAULT 0,
            json BLOB NOT NULL
        );
        CREATE UNIQUE INDEX folders_by_name ON folders (name COLLATE NOCASE);
        ALTER TABLE meetings ADD COLUMN folder_id TEXT;
        CREATE INDEX meetings_by_folder ON meetings (folder_id);
        """,
        // v6 (T89, spec 0008): one notes document per meeting replaces "Your notes" and the private scratchpad. Revisions
        // are immutable JSON; the newest is current. `migrateData(to: 6)` builds each meeting's first document in the same
        // transaction. The old tables stay (read by that step, purged on deletion).
        """
        CREATE TABLE notes_document_revisions (
            id TEXT PRIMARY KEY,
            meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            created_at REAL NOT NULL,
            json BLOB NOT NULL
        );
        CREATE INDEX notes_documents_by_meeting ON notes_document_revisions (meeting_id, created_at);
        """,
        // v7 (T111, spec 0010): derived contextual-search index. Chunks of each meeting's *current* transcript (chunk-v1),
        // rewritten in the same transaction as the search index; vectors keyed by chunk content hash + encoder producer, so
        // unchanged text keeps its vector and text that is gone can't get one back. Per-meeting state: a generation bumped
        // on every rewrite (stale-answer checks) and the meeting start used by date filters. `migrateData(to: 7)` chunks
        // existing meetings (no embeddings: the writer is never held for model work).
        """
        CREATE TABLE context_chunks (
            meeting_id TEXT NOT NULL,
            ordinal INTEGER NOT NULL,
            chunking TEXT NOT NULL,
            content_hash TEXT NOT NULL,
            text TEXT NOT NULL,
            spans TEXT NOT NULL,
            first_line INTEGER NOT NULL,
            last_line INTEGER NOT NULL,
            start_ns INTEGER NOT NULL,
            revision_id TEXT NOT NULL,
            PRIMARY KEY (meeting_id, ordinal)
        );
        CREATE INDEX context_chunks_by_hash ON context_chunks (content_hash);
        CREATE TABLE context_vectors (
            content_hash TEXT NOT NULL,
            producer TEXT NOT NULL,
            dims INTEGER NOT NULL,
            vector BLOB NOT NULL,
            created_at REAL NOT NULL,
            PRIMARY KEY (content_hash, producer)
        );
        CREATE TABLE context_failures (
            content_hash TEXT NOT NULL,
            producer TEXT NOT NULL,
            attempts INTEGER NOT NULL,
            error TEXT NOT NULL,
            PRIMARY KEY (content_hash, producer)
        );
        CREATE TABLE context_meeting_state (
            meeting_id TEXT PRIMARY KEY,
            generation INTEGER NOT NULL,
            start_at REAL NOT NULL
        );
        """,
        // v8 (T119): no schema change. The personal-mic speaker is now shown under the user's name, so the search
        // index and contextual chunks are rebuilt once from current content (migrateData).
        "SELECT 1;",
    ]

    /// Steps that rewrite stored content after a version's SQL, in that migration's transaction.
    static func migrateData(to version: Int, _ db: SQLiteDB) throws {
        switch version {
        case 6: try MeetingStore.migrateToNotesDocuments(db)
        case 7: try MeetingStore.rechunkAll(db)
        case 8: try MeetingStore.reindexAll(db)
        default: break
        }
    }

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
                try migrateData(to: i + 1, db)
                try db.exec("PRAGMA user_version = \(i + 1)")
            }
        }
        return current
    }
}
