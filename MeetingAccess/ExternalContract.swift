public import Foundation

/// The external read contract (spec 0009 §1): what tools outside Amaranth — bulk export (T99), and later the MCP
/// adapter (Milestone T) — receive about a meeting. Transport-independent and versioned separately from the
/// `amaranth-export` v2 single-meeting JSON.
///
/// Built from what the app *shows*: the transcript with corrections, deleted lines and trims applied and the speaker
/// names the user gave; the notes document as the Notes tab shows it. Never included: original or hidden revisions,
/// the generated summary's original body, raw calendar payloads, attendee emails, audio, work checkpoints, model
/// prompts or local paths. Every passage carries a citation that resolves only against current content.
public enum ExternalSchema {
    public static let format = "amaranth-meeting"
    /// 1 (T97, 2026-11-03). Any change to the shape of `MeetingSnapshot` bumps this and adds a compatibility fixture.
    public static let version = 1
}

/// Shared ceilings for every external operation (spec 0009 §2). Requests over a limit are rejected, never truncated
/// silently; content over the response budget is paged with continuation metadata.
public enum AccessLimits {
    public static let maxQueryCharacters = 2_000
    public static let maxMeetingIDs = 50
    public static let maxListRows = 50
    public static let maxSearchPassages = 20
    /// UTF-8 bytes of one encoded response.
    public static let maxResponseBytes = 64 * 1024
    public static let requestDeadline: TimeInterval = 30
    /// Longest identifier accepted anywhere (meeting, revision, segment, word, block IDs).
    public static let maxIdentifierLength = 128
    /// Longest citation URL accepted.
    public static let maxURLLength = 2_048
}

/// Structured errors shared by all external operations (spec 0009 §2).
public enum AccessError: Error, Equatable, Sendable, Codable {
    /// Malformed or out-of-bounds input; `detail` says which field.
    case invalidRequest(String)
    /// No such meeting, or it was deleted, or it is outside the caller's scope (indistinguishable on purpose).
    case unavailable
    /// The caller's expected fingerprint or cited revision no longer matches current content.
    case changed(currentFingerprint: String?)
    /// The search query can't be run (empty after normalization, or only syntax).
    case badQuery(String)
    /// A cursor from an earlier library state, another query or another build: start the listing again.
    case restartRequired
    case cancelled
    case deadlineExceeded
    case `internal`(String)

    public var code: String {
        switch self {
        case .invalidRequest: "invalid_request"
        case .unavailable: "unavailable"
        case .changed: "changed"
        case .badQuery: "bad_query"
        case .restartRequired: "restart_required"
        case .cancelled: "cancelled"
        case .deadlineExceeded: "deadline_exceeded"
        case .internal: "internal"
        }
    }
}

/// One meeting as the user currently sees it: a consistent per-meeting read.
public struct MeetingSnapshot: Codable, Equatable, Sendable {
    public var format: String = ExternalSchema.format
    public var version: Int = ExternalSchema.version
    public var libraryID: String
    public var meetingID: String
    /// SHA-256 (hex) over everything below except `readAt`: changes with any title, people, folder, speaker, edit,
    /// notes or transcript change.
    public var fingerprint: String
    /// When this snapshot was read. Each meeting has its own; a multi-meeting export can mix read times.
    public var readAt: Date
    public var title: String
    /// Recording start (UTC), or when the meeting was created if capture never started.
    public var start: Date
    /// IANA time zone where it was recorded, when known.
    public var timeZone: String?
    /// Session-timeline length including pauses and gaps, in integer nanoseconds.
    public var durationNs: Int64
    public var folder: FolderRef?
    /// Names only: a person listed for the meeting is not a claim they spoke any passage.
    public var people: [String]
    public var state: ContentState
    public var revisions: Revisions
    /// Provenance of the generated notes the shown notes were composed from. The generated body is never included.
    public var generatedNotes: GeneratedNotesProvenance?
    public var speakers: [SpeakerRef]
    /// Displayed transcript lines in time order (empty when there is no transcript).
    public var transcript: [TranscriptLine]
    /// Stretches with audio but no transcript, or no audio, listed rather than omitted.
    public var gaps: [Gap]
    /// The notes document as shown, every block with its author.
    public var notes: [NoteLine]
    /// Plain-language disclosures a reader should see with this content.
    public var limitations: [String]
    public var citation: String

    public struct FolderRef: Codable, Equatable, Sendable { public var id: String; public var name: String }

    public struct ContentState: Codable, Equatable, Sendable {
        /// notStarted, recording, paused, saving, saved, savedWithGaps, interrupted
        public var capture: String
        /// present, deleted (the user deleted the audio; text remains)
        public var audio: String
        /// none, processing, failed, provisional (live text, may change), final
        public var transcript: String
        /// none, generating, failed, ready
        public var notes: String
        /// Generated notes come from an older transcript or edits made since.
        public var notesStale: Bool
        /// A newer generated version waits for the user to replace or dismiss it; the shown notes are unchanged.
        public var newerNotesPending: Bool
        /// Edits that no longer apply cleanly to the current transcript and wait for the user's review.
        public var editsNeedingReview: Int
        /// The user deleted transcript lines or trimmed the start/end (T96).
        public var transcriptLinesRemoved: Bool
    }

    public struct Revisions: Codable, Equatable, Sendable {
        public var transcript: String?
        /// final or provisional
        public var transcriptKind: String?
        public var notes: String?
        /// Highest edit sequence reflected (0 = no edits).
        public var editSequence: Int
    }

    public struct GeneratedNotesProvenance: Codable, Equatable, Sendable {
        public var revisionID: String
        public var promptVersion: String
        public var generatedAt: Date
        public var fromTranscriptRevision: String
        public var stale: Bool
    }

    public struct SpeakerRef: Codable, Equatable, Sendable { public var id: String; public var name: String }

    public struct TranscriptLine: Codable, Equatable, Sendable {
        /// Segment ID (the citation `ref`) and first word ID (the citation `word`).
        public var segmentID: String
        public var wordID: String
        public var startNs: Int64
        public var endNs: Int64
        /// microphone or systemOutput
        public var source: String
        /// The label the app shows: a name, "Speaker 2", "Unknown speaker", or "A + B (overlapping)".
        public var speaker: String
        public var speakerIDs: [String]
        public var text: String
        /// overlap, uncertainSpeaker, questionableText, probableEcho, corrected
        public var flags: [String]
        public var citation: String
    }

    public struct Gap: Codable, Equatable, Sendable {
        public var source: String
        public var startNs: Int64
        public var endNs: Int64
        public var reason: String
    }

    public struct NoteLine: Codable, Equatable, Sendable {
        public var blockID: String
        /// heading, paragraph, bullet
        public var kind: String
        /// The generated section a heading starts (overview, topics, decisions, nextSteps, openQuestions, limitations, alsoNoted).
        public var section: String?
        public var text: String
        public var detail: String?
        /// user (a person wrote or edited it; never something said) or model (generated).
        public var author: String
        /// Seconds from the recording's start when a user line was typed during the recording.
        public var typedAtSeconds: Double?
        public var uncertain: Bool
        public var evidence: [Evidence]
        public var citation: String
    }

    /// Where a generated line came from. IDs and times only: evidence never carries text.
    public struct Evidence: Codable, Equatable, Sendable {
        /// transcript or userNote
        public var type: String
        /// current: resolves in the content above; removed: those words or that line are no longer shown (deleted,
        /// trimmed or edited); otherRevision: cites an earlier transcript (the notes are stale).
        public var status: String
        public var revisionID: String
        public var segmentID: String?
        public var firstWordID: String?
        public var lastWordID: String?
        public var blockID: String?
        public var startNs: Int64?
        /// Present only when `status` is current.
        public var citation: String?
    }
}
