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

/// Someone in the meeting (T49). Free text, or `.calendar` when added from a linked event's attendees (T58).
/// Not tied to transcript speakers: naming a speaker is still a separate edit.
public struct Person: Hashable, Sendable, Codable {
    public enum Source: String, Hashable, Sendable, Codable {
        case manual
        case calendar
    }
    public var name: String
    public var source: Source
    /// An attendee's address, kept only when "Keep attendee email addresses" is on (off by default, T58/T61). Never
    /// exported.
    public var email: String?
    public init(name: String, source: Source = .manual, email: String? = nil) {
        self.name = name
        self.source = source
        self.email = email
    }
}

/// The calendar event a recording belongs to (T49): a snapshot taken when the user linked it (T57, docs/decisions/0006).
/// `identifier` is the provider's event identifier, opaque to Amaranth.
public struct LinkedEvent: Hashable, Sendable, Codable {
    public enum Source: String, Hashable, Sendable, Codable {
        /// The calendars configured on this Mac, read through EventKit.
        case eventKit
    }
    public var identifier: String
    public var title: String
    public var start: Date
    public var end: Date
    public var calendarName: String?
    public var source: Source
    /// Invited people without a display name, skipped rather than stored (T58); nil when there were none.
    public var unnamedAttendees: Int?
    public init(identifier: String, title: String, start: Date, end: Date, calendarName: String? = nil, source: Source = .eventKit,
                unnamedAttendees: Int? = nil) {
        self.identifier = identifier
        self.title = title
        self.start = start
        self.end = end
        self.calendarName = calendarName
        self.source = source
        self.unnamedAttendees = unnamedAttendees
    }
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
    /// Optional metadata (T49), additive with defaults: rows written before it decode with no people and no event, and
    /// a meeting without them encodes exactly as before. The store changes these only through its setters.
    public var people: [Person] = []
    public var linkedEvent: LinkedEvent?

    public init(id: MeetingID = MeetingID(), title: String, createdAt: Date, clock: SessionClock? = nil,
                captureState: CaptureState = .idle, selectedSources: SourceSelection = .both,
                retention: RetentionPolicy = .untilUserDeletes, audio: AudioAvailability = .present,
                duration: SessionDuration = .init(nanoseconds: 0), currentTranscriptRevisionID: RevisionID? = nil,
                provisionalTranscriptRevisionID: RevisionID? = nil, currentSummaryRevisionID: RevisionID? = nil,
                deletedAt: Date? = nil, people: [Person] = [], linkedEvent: LinkedEvent? = nil) {
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
        self.people = people
        self.linkedEvent = linkedEvent
    }

    public var canPlayAudio: Bool { audio == .present && deletedAt == nil }
}

extension Meeting {
    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, clock, captureState, selectedSources, retention, audio, duration
        case currentTranscriptRevisionID, provisionalTranscriptRevisionID, currentSummaryRevisionID, deletedAt
        case people, linkedEvent
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(MeetingID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        clock = try c.decodeIfPresent(SessionClock.self, forKey: .clock)
        captureState = try c.decode(CaptureState.self, forKey: .captureState)
        selectedSources = try c.decode(SourceSelection.self, forKey: .selectedSources)
        retention = try c.decode(RetentionPolicy.self, forKey: .retention)
        audio = try c.decode(AudioAvailability.self, forKey: .audio)
        duration = try c.decode(SessionDuration.self, forKey: .duration)
        currentTranscriptRevisionID = try c.decodeIfPresent(RevisionID.self, forKey: .currentTranscriptRevisionID)
        provisionalTranscriptRevisionID = try c.decodeIfPresent(RevisionID.self, forKey: .provisionalTranscriptRevisionID)
        currentSummaryRevisionID = try c.decodeIfPresent(RevisionID.self, forKey: .currentSummaryRevisionID)
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        people = try c.decodeIfPresent([Person].self, forKey: .people) ?? []
        linkedEvent = try c.decodeIfPresent(LinkedEvent.self, forKey: .linkedEvent)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(clock, forKey: .clock)
        try c.encode(captureState, forKey: .captureState)
        try c.encode(selectedSources, forKey: .selectedSources)
        try c.encode(retention, forKey: .retention)
        try c.encode(audio, forKey: .audio)
        try c.encode(duration, forKey: .duration)
        try c.encodeIfPresent(currentTranscriptRevisionID, forKey: .currentTranscriptRevisionID)
        try c.encodeIfPresent(provisionalTranscriptRevisionID, forKey: .provisionalTranscriptRevisionID)
        try c.encodeIfPresent(currentSummaryRevisionID, forKey: .currentSummaryRevisionID)
        try c.encodeIfPresent(deletedAt, forKey: .deletedAt)
        if !people.isEmpty { try c.encode(people, forKey: .people) }
        try c.encodeIfPresent(linkedEvent, forKey: .linkedEvent)
    }
}
