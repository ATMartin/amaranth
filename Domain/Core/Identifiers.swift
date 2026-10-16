public import Foundation

/// A strongly typed identifier. The phantom `Tag` prevents mixing, e.g., a `WordID` with a `SpeakerID`.
public struct Identifier<Tag>: Hashable, Sendable, Codable, CustomStringConvertible, Comparable {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(uuid: UUID = UUID()) { self.rawValue = uuid.uuidString.lowercased() }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public var description: String { rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum MeetingTag {}
public enum SegmentTag {}
public enum EpochTag {}
public enum CaptureEventTag {}
public enum RevisionTag {}
public enum TranscriptSegmentTag {}
public enum WordTag {}
public enum SpeakerTag {}
public enum ClusterTag {}
public enum EditTag {}
public enum SummaryItemTag {}
public enum JobTag {}
public enum ModelManifestTag {}
public enum ScratchpadTag {}

public typealias MeetingID = Identifier<MeetingTag>
public typealias AudioSegmentID = Identifier<SegmentTag>
public typealias EpochID = Identifier<EpochTag>
public typealias CaptureEventID = Identifier<CaptureEventTag>
/// Immutable revision identifier shared by transcript, summary and scratchpad revisions.
/// A revision's content never changes after publication; edits produce a new revision.
public typealias RevisionID = Identifier<RevisionTag>
public typealias TranscriptSegmentID = Identifier<TranscriptSegmentTag>
/// Stable within a single transcript revision.
public typealias WordID = Identifier<WordTag>
/// Session-scoped speaker identity. Never a cross-meeting voice profile.
public typealias SpeakerID = Identifier<SpeakerTag>
/// Opaque diarizer cluster label. Has no meaning outside one diarization run.
public typealias ClusterID = Identifier<ClusterTag>
public typealias EditID = Identifier<EditTag>
public typealias SummaryItemID = Identifier<SummaryItemTag>
public typealias JobID = Identifier<JobTag>
public typealias ModelManifestID = Identifier<ModelManifestTag>
public typealias ScratchpadID = Identifier<ScratchpadTag>
