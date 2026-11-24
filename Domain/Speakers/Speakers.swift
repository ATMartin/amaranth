public import Foundation

/// A cluster reference: which diarization run and which cluster within it.
public struct ClusterRef: Hashable, Sendable, Codable {
    public var diarizationRunID: RevisionID
    public var cluster: ClusterID
    public init(diarizationRunID: RevisionID, cluster: ClusterID) {
        self.diarizationRunID = diarizationRunID
        self.cluster = cluster
    }
}

/// A session-scoped anonymous speaker. A user-entered `displayName` changes a mapping only;
/// it is not evidence that every turn was correctly clustered.
public struct Speaker: Hashable, Sendable, Codable, Identifiable {
    public var id: SpeakerID
    /// Automatic anonymous label, e.g. "Speaker 2".
    public var label: String
    public var displayName: String?
    public var clusters: [ClusterRef]
    /// Source where this speaker was first observed; a hint, not identity.
    public var primarySource: SourceKind?

    public init(id: SpeakerID = SpeakerID(), label: String, displayName: String? = nil,
                clusters: [ClusterRef] = [], primarySource: SourceKind? = nil) {
        self.id = id
        self.label = label
        self.displayName = displayName
        self.clusters = clusters
        self.primarySource = primarySource
    }

    public var shownName: String { displayName ?? defaultName }

    /// The personal-mic speaker (T119): in personal-mic mode the reconciler gives every microphone word to one speaker
    /// with a `-mic` id. That speaker is the user unless they rename it to someone else.
    public var isLocalUser: Bool { primarySource == .microphone && id.rawValue.hasSuffix("-mic") }

    /// The name shown when the user has not named this speaker: the user's own name for the personal-mic speaker,
    /// the anonymous label otherwise. Derived at display time, so stored revisions need no reprocessing.
    public var defaultName: String { isLocalUser ? Self.localUserName : label }

    /// Tests pin the user's name with `Speaker.$localUserNameOverride.withValue(...)`.
    @TaskLocal public static var localUserNameOverride: String?

    /// The macOS full name of the user running the app, or "Me" when it is empty.
    public static var localUserName: String {
        if let o = localUserNameOverride { return o }
        let n = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "Me" : n
    }
}

/// Inclusive word range within a specific revision.
public struct WordRange: Hashable, Sendable, Codable {
    public var revisionID: RevisionID
    public var first: WordID
    public var last: WordID
    public init(revisionID: RevisionID, first: WordID, last: WordID) {
        self.revisionID = revisionID
        self.first = first
        self.last = last
    }
}

public enum SpeakerTarget: Hashable, Sendable, Codable {
    case existing(SpeakerID)
    /// Create a new speaker with this ID (assigned client-side so the edit is replayable).
    case new(SpeakerID, label: String)
    case unknown
}

public enum EditOperation: Hashable, Sendable, Codable {
    case renameSpeaker(SpeakerID, displayName: String?)
    case mergeSpeakers(sources: [SpeakerID], into: SpeakerID)
    /// Reassign a selected turn/word range to a different or new speaker.
    case reassign(WordRange, to: SpeakerTarget)
    case markUncertain(WordRange)
    case correctText(WordRange, replacement: String)
    /// Removes a transcript line from what the user sees, searches, exports and generates notes from (T96). The machine
    /// revision keeps the words, like a correction keeps the original; the audio is untouched.
    case deleteText(WordRange)
    /// Keeps only the transcript from `start` and/or before `end` (T96: “Start from Here…” / “End Here…”). Time-based, so
    /// it still applies after reprocessing. The matching audio is deleted separately (CaptureTrim).
    case trimTranscript(start: SessionTime?, end: SessionTime?)
}

public enum EditConflictState: String, Hashable, Sendable, Codable {
    /// Applied cleanly to the current machine revision.
    case applied
    /// Rebasing onto a new machine revision was ambiguous; needs user review instead of overwriting.
    case needsReview
    /// User dismissed after review.
    case discarded
}

/// A user correction. Stored separately from machine revisions and reapplied after reprocessing.
public struct UserEdit: Hashable, Sendable, Codable, Identifiable {
    public var id: EditID
    public var meetingID: MeetingID
    /// Machine revision this edit was authored against.
    public var baseRevisionID: RevisionID
    /// Monotonic order of edits within a meeting.
    public var sequence: Int
    public var createdAt: Date
    public var operation: EditOperation
    /// Lineage: the edit this one was rebased from, if any.
    public var rebasedFrom: EditID?
    public var conflict: EditConflictState

    public init(id: EditID = EditID(), meetingID: MeetingID, baseRevisionID: RevisionID, sequence: Int,
                createdAt: Date, operation: EditOperation, rebasedFrom: EditID? = nil,
                conflict: EditConflictState = .applied) {
        self.id = id
        self.meetingID = meetingID
        self.baseRevisionID = baseRevisionID
        self.sequence = sequence
        self.createdAt = createdAt
        self.operation = operation
        self.rebasedFrom = rebasedFrom
        self.conflict = conflict
    }
}
