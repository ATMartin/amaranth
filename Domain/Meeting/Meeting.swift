public import Foundation

public enum RetentionPolicy: String, Hashable, Sendable, Codable {
    /// Confirmed default: keep audio locally until the user explicitly deletes it.
    case untilUserDeletes
}

public enum AudioAvailability: String, Hashable, Sendable, Codable {
    case present
    /// "Delete audio only" was used: transcript/notes remain, playback and retranscription are disabled.
    case deletedByUser
}

public struct Meeting: Hashable, Sendable, Codable, Identifiable {
    public var id: MeetingID
    public var title: String
    public var createdAt: Date
    /// Present once capture has actually started.
    public var clock: SessionClock?
    public var captureState: CaptureState
    public var selectedSources: SourceSelection
    public var retention: RetentionPolicy
    public var audio: AudioAvailability
    /// Session-timeline length including pauses and gaps.
    public var duration: SessionDuration
    public var currentTranscriptRevisionID: RevisionID?
    /// Latest live/provisional revision, while recording or until a final revision supersedes it.
    public var provisionalTranscriptRevisionID: RevisionID?
    public var currentSummaryRevisionID: RevisionID?
    /// Tombstone. Once set, no job result may publish for this meeting.
    public var deletedAt: Date?

    public init(id: MeetingID = MeetingID(), title: String, createdAt: Date, clock: SessionClock? = nil,
                captureState: CaptureState = .idle, selectedSources: SourceSelection = .both,
                retention: RetentionPolicy = .untilUserDeletes, audio: AudioAvailability = .present,
                duration: SessionDuration = .init(nanoseconds: 0), currentTranscriptRevisionID: RevisionID? = nil,
                provisionalTranscriptRevisionID: RevisionID? = nil, currentSummaryRevisionID: RevisionID? = nil,
                deletedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.clock = clock
        self.captureState = captureState
        self.selectedSources = selectedSources
        self.retention = retention
        self.audio = audio
        self.duration = duration
        self.currentTranscriptRevisionID = currentTranscriptRevisionID
        self.provisionalTranscriptRevisionID = provisionalTranscriptRevisionID
        self.currentSummaryRevisionID = currentSummaryRevisionID
        self.deletedAt = deletedAt
    }

    public var canPlayAudio: Bool { audio == .present && deletedAt == nil }
}
