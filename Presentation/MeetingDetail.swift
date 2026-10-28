public import Foundation
public import Domain
public import Storage

/// Everything the meeting detail screen shows, loaded in one pass from the store. Audio and processing states are
/// independent; nothing here implies certainty that the data does not support.
public struct MeetingDetail: Sendable {
    public var meeting: Meeting
    public var status: MeetingStatus
    public var events: [CaptureEvent]
    public var jobs: [ProcessingJob]
    /// Machine revision currently published (corrections NOT applied — use `rows` / `displayTranscript` to show).
    public var transcript: TranscriptRevision?
    public var displayTranscript: TranscriptRevision?
    public var rows: [TranscriptRow]
    public var edits: [UserEdit]
    public var summary: SummaryRevision?
    public var userNotes: ManualNotesRevision?
    public var scratchpad: ScratchpadRevision?
    public var diskUsage: MeetingStore.DiskUsage
    public var segments: [AudioSegmentRecord]

    public var editsNeedingReview: [UserEdit] { edits.filter { $0.conflict == .needsReview } }
    /// True when no final transcript exists yet and the live (provisional) revision is shown instead.
    public var showingProvisional: Bool { transcript?.kind == .provisional }

    /// Why playback is unavailable, or nil when it is available.
    public var playbackUnavailableReason: String? {
        if meeting.audio == .deletedByUser { return "Audio was deleted. The transcript and notes remain." }
        if segments.isEmpty { return "No recorded audio is available for this meeting." }
        return nil
    }

    public var notesJob: ProcessingJob? { jobs.filter { $0.key.stage == .notes }.max { $0.updatedAt < $1.updatedAt } }

    public enum NotesState: Equatable, Sendable {
        case none
        case waiting(String)
        case generating(Double)
        case failed(String)
        /// Notes exist. `regenerationError` is set when a later regeneration failed (the shown notes are the prior ones).
        case ready(stale: Bool, regenerationError: String?)
        case unavailable(String)
    }

    /// What the notes panel should say, combining the current summary with the latest notes job.
    public func notesState(notesModelInstalled: Bool) -> NotesState {
        if let j = notesJob, !j.state.isTerminal {
            switch j.state {
            case .running: return .generating(j.progress)
            case .suspended: return .waiting(j.suspension == .recordingActive ? "Waiting — paused while recording" : "Waiting — paused to keep your Mac responsive")
            default: return .waiting("Queued")
            }
        }
        if let s = summary {
            let failed = notesJob.flatMap { $0.state == .failed && $0.updatedAt > s.createdAt ? ($0.errorCode ?? "unknown error") : nil }
            return .ready(stale: s.isStale, regenerationError: failed)
        }
        if let j = notesJob, j.state == .failed { return .failed(j.errorCode ?? "unknown error") }
        if !notesModelInstalled { return .unavailable("Install the model pack to generate notes. Recording and transcripts don't need it.") }
        if transcript == nil || showingProvisional { return .unavailable("Notes are generated after the final transcript is ready.") }
        // Words are final but speakers are still coming: offering "Generate" here would build notes without speakers
        // (stale on arrival) and hold up reconcile behind them. If diarization failed, nothing is pending and the user
        // may generate from the words alone.
        if transcript?.stage == .asr, jobs.contains(where: { [.diarize, .reconcile].contains($0.key.stage) && !$0.state.isTerminal }) {
            return .waiting("Notes start when speakers are identified")
        }
        return .none
    }

    public static func load(_ store: MeetingStore, _ id: MeetingID) throws -> MeetingDetail? {
        guard let m = try store.meeting(id), m.deletedAt == nil else { return nil }
        let events = try store.events(id)
        let jobs = try store.jobs(meeting: id)
        let edits = try store.edits(id)
        // Until a final transcript exists, show the live provisional one (labelled as such in the UI).
        let transcript = try (m.currentTranscriptRevisionID ?? m.provisionalTranscriptRevisionID).flatMap { try store.transcriptRevision($0) }
        let display = transcript?.applyingTextCorrections(edits)
        return MeetingDetail(meeting: m, status: MeetingStatus(meeting: m, jobs: jobs, events: events), events: events, jobs: jobs,
                             transcript: transcript, displayTranscript: display,
                             rows: transcript.map { TranscriptRows.build($0, edits: edits) } ?? [], edits: edits,
                             summary: try store.currentSummary(id), userNotes: try store.latestManualNotes(id),
                             scratchpad: try store.latestScratchpad(id), diskUsage: store.diskUsage(id), segments: try store.segments(id))
    }
}

/// A row in the meeting library.
public struct MeetingListItem: Identifiable, Hashable, Sendable {
    public var id: MeetingID
    public var title: String
    public var createdAt: Date
    public var duration: SessionDuration
    public var status: MeetingStatus
    public var hasNotes: Bool
    /// A final or live transcript exists, so the meeting can be exported (what `MeetingDetail.transcript != nil` says).
    public var hasTranscript: Bool = false
    /// The folder the meeting is filed in (T40); nil = unfiled.
    public var folderID: FolderID?

    public static func load(_ store: MeetingStore, limit: Int = 500) throws -> [MeetingListItem] {
        try store.meetings().prefix(limit).map { m in
            let jobs = try store.jobs(meeting: m.id)
            return MeetingListItem(id: m.id, title: m.title, createdAt: m.createdAt, duration: m.duration,
                                   status: MeetingStatus(meeting: m, jobs: jobs, events: try store.events(m.id)),
                                   hasNotes: m.currentSummaryRevisionID != nil,
                                   hasTranscript: (m.currentTranscriptRevisionID ?? m.provisionalTranscriptRevisionID) != nil,
                                   folderID: m.folderID)
        }
    }
}

/// Explicit wording for destructive actions: what is removed, what stays, and that it cannot be undone.
public enum DestructiveAction: Sendable {
    case deleteAudioOnly
    case deleteMeeting

    public func confirmationTitle(_ title: String) -> String {
        switch self {
        case .deleteAudioOnly: "Delete the audio of “\(title)”?"
        case .deleteMeeting: "Delete “\(title)” completely?"
        }
    }

    public func explanation(_ usage: MeetingStore.DiskUsage) -> String {
        let bytes = ByteCountFormatter.string(fromByteCount: usage.totalBytes, countStyle: .file)
        return switch self {
        case .deleteAudioOnly:
            "Removes the recorded audio and processing files (\(bytes)). The transcript, notes and your edits stay and remain searchable; playback and re-transcription will no longer be possible. This cannot be undone."
        case .deleteMeeting:
            "Removes the audio, transcript, notes, your notes and edits, and search entries (\(bytes)). Files you exported earlier are not affected. This cannot be undone."
        }
    }

    public var buttonTitle: String { self == .deleteAudioOnly ? "Delete Audio" : "Delete Meeting" }
}
