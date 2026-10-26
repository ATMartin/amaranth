public import Foundation
public import Domain

/// Disk usage and deletion (T11). Originals are kept until the user deletes them (retention `untilUserDeletes`).
extension MeetingStore {
    public struct DiskUsage: Hashable, Sendable {
        /// Original recorded audio (CAF segments, staging, journal).
        public var originalAudioBytes: Int64
        /// Re-creatable files: analysis audio, processing checkpoints and stage outputs.
        public var derivedBytes: Int64
        public var totalBytes: Int64 { originalAudioBytes + derivedBytes }
        public init(originalAudioBytes: Int64, derivedBytes: Int64) { self.originalAudioBytes = originalAudioBytes; self.derivedBytes = derivedBytes }
    }

    public func workDirectory(_ id: MeetingID) -> URL { root.appending(path: "work/\(id.rawValue)") }

    public func diskUsage(_ id: MeetingID) -> DiskUsage {
        DiskUsage(originalAudioBytes: Self.bytes(meetingDirectory(id)), derivedBytes: Self.bytes(workDirectory(id)))
    }

    static func bytes(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    /// "Delete audio only": removes the original audio and every audio derivative (prepared analysis audio, any WAV).
    /// Text stage outputs stay — the transcript and diarization results that speaker edits re-reconcile from, and notes
    /// checkpoints — so edits keep working. Playback and retranscription are disabled (`Meeting.audio ==
    /// .deletedByUser`). Call after the scheduler has cancelled the meeting's audio stages.
    public func deleteAudio(_ id: MeetingID) throws {
        guard var m = try meeting(id), m.deletedAt == nil else { return }
        m.audio = .deletedByUser
        try upsertMeeting(m)   // first: from here on nothing may start reading audio
        try withDB { db in
            try db.run("DELETE FROM audio_segments WHERE meeting_id=?", [.text(id.rawValue)])
        }
        try? FileManager.default.removeItem(at: meetingDirectory(id))
        Self.removeAudioDerivatives(in: workDirectory(id))
        try checkpointAndTruncateWAL()
    }

    /// Removes `prepare-*` stage folders (16 kHz analysis audio) and any audio file left elsewhere under `dir`.
    static func removeAudioDerivatives(in dir: URL) {
        let fm = FileManager.default
        for stage in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where stage.lastPathComponent.hasPrefix("prepare-") {
            try? fm.removeItem(at: stage)
        }
        let audio: Set<String> = ["wav", "caf", "aiff", "m4a", "pcm"]
        for case let f as URL in fm.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects ?? [] where audio.contains(f.pathExtension.lowercased()) {
            try? fm.removeItem(at: f)
        }
    }

    /// Complete deletion, after `JobScheduler.delete` tombstoned the meeting and cancelled its jobs. Every row with
    /// meeting content, every search entry and every file (audio, derivatives, checkpoints that hold transcript text)
    /// is removed. A scrubbed tombstone row (ID and deletion time only) stays so a late worker result can never publish.
    public func purgeMeeting(_ id: MeetingID) throws {
        guard let m = try meeting(id) else { return }
        precondition(m.deletedAt != nil, "tombstone the meeting (JobScheduler.delete) before purging")
        try withDB { db in
            try db.transaction {
                for table in ["search_index", "capture_epochs", "audio_segments", "capture_events", "processing_jobs", "transcript_revisions",
                              "diarization_results", "user_edits", "summary_revisions", "scratchpad_revisions", "manual_notes_revisions"] {
                    try db.run("DELETE FROM \(table) WHERE meeting_id=?", [.text(id.rawValue)])
                }
                let scrubbed = Meeting(id: id, title: "", createdAt: m.createdAt, captureState: m.captureState, selectedSources: m.selectedSources,
                                       audio: .deletedByUser, deletedAt: m.deletedAt)
                try db.run("""
                    UPDATE meetings SET title='', audio=?, duration_ns=0, current_transcript_revision=NULL, provisional_transcript_revision=NULL,
                      current_summary_revision=NULL, linked_event_id=NULL, json=? WHERE id=?
                    """, [.text(AudioAvailability.deletedByUser.rawValue), .blob(try ContractCoding.encode(scrubbed)), .text(id.rawValue)])
            }
        }
        try? FileManager.default.removeItem(at: meetingDirectory(id))
        try? FileManager.default.removeItem(at: workDirectory(id))
        try checkpointAndTruncateWAL()
    }

    /// With `secure_delete` on, deleted rows are zeroed in the main file; the FTS index is merged so deleted terms are
    /// dropped; checkpointing moves the WAL into the file and truncates it so no deleted text lingers there either.
    func checkpointAndTruncateWAL() throws {
        try withDB { db in
            // FTS5 deletes by writing tombstones; the deleted terms stay in index segments until they are merged.
            try db.run("INSERT INTO search_index(search_index) VALUES('optimize')")
            _ = try db.run("PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }
}
