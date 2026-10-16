import Foundation

/// Microphone usage mode. Source identity never guarantees one human speaker.
public enum MicrophoneMode: String, Hashable, Sendable, Codable {
    /// Personal headset: propose one local speaker label for the mic, still correctable.
    case personal
    /// Shared room: diarize the mic track too.
    case room
}

public struct DiarizationConstraints: Hashable, Sendable, Codable {
    public var minSpeakers: Int?
    public var maxSpeakers: Int?
    public var microphoneMode: MicrophoneMode
    /// Upper bound for clustering working memory (plan §7: bounded clustering).
    public var maxClusteringMemoryBytes: Int

    public init(minSpeakers: Int? = nil, maxSpeakers: Int? = 8, microphoneMode: MicrophoneMode = .personal,
                maxClusteringMemoryBytes: Int = 512 * 1024 * 1024) {
        self.minSpeakers = minSpeakers
        self.maxSpeakers = maxSpeakers
        self.microphoneMode = microphoneMode
        self.maxClusteringMemoryBytes = maxClusteringMemoryBytes
    }
}

public struct SpeakerTurn: Hashable, Sendable, Codable {
    public var interval: SessionInterval
    public var source: SourceKind
    public var cluster: ClusterID
    public var rawScore: Double?

    public init(interval: SessionInterval, source: SourceKind, cluster: ClusterID, rawScore: Double? = nil) {
        self.interval = interval
        self.source = source
        self.cluster = cluster
        self.rawScore = rawScore
    }
}

/// Output of one full-meeting diarization pass over one source. Cluster IDs are opaque and
/// meeting-wide consistent within this run; they are not names.
public struct DiarizationResult: Hashable, Sendable, Codable, Identifiable {
    public var id: RevisionID
    public var meetingID: MeetingID
    public var source: SourceKind
    public var producer: ProducerInfo
    public var clusters: [ClusterID]
    public var turns: [SpeakerTurn]
    /// Intervals where two or more clusters are simultaneously active.
    public var overlaps: [SessionInterval]

    public init(id: RevisionID = RevisionID(), meetingID: MeetingID, source: SourceKind, producer: ProducerInfo,
                clusters: [ClusterID], turns: [SpeakerTurn], overlaps: [SessionInterval]) {
        self.id = id
        self.meetingID = meetingID
        self.source = source
        self.producer = producer
        self.clusters = clusters
        self.turns = turns
        self.overlaps = overlaps
    }
}
