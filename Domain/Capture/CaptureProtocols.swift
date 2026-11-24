import Foundation

public struct AudioSourceConfiguration: Hashable, Sendable {
    public var meetingID: MeetingID
    public var source: SourceKind
    /// Core Audio device UID for a pinned input; nil means the current default input.
    public var deviceUID: String?
    /// Whether to fall back to the default device when a pinned device disappears (user preference).
    public var allowDefaultDeviceFallback: Bool
    /// Bundle identifiers/PIDs to exclude from system capture (always includes Amaranth itself).
    public var excludedProcessIDs: [Int32]

    public init(meetingID: MeetingID, source: SourceKind, deviceUID: String? = nil,
                allowDefaultDeviceFallback: Bool = false, excludedProcessIDs: [Int32] = []) {
        self.meetingID = meetingID
        self.source = source
        self.deviceUID = deviceUID
        self.allowDefaultDeviceFallback = allowDefaultDeviceFallback
        self.excludedProcessIDs = excludedProcessIDs
    }
}

/// Events emitted off the realtime thread.
public enum AudioSourceEvent: Hashable, Sendable {
    case started(format: AudioFormat, deviceUID: String?, deviceName: String?, hostTimeNanos: UInt64)
    case formatChanged(AudioFormat)
    case deviceLost(reasonCode: String)
    case deviceRecovered(deviceUID: String?, deviceName: String?)
    case overrun(lostFrames: Int64)
    case permissionDenied
    case stopped
}

public enum AudioSourceError: Error, Hashable, Sendable {
    case permissionDenied(SourceKind)
    case deviceUnavailable(String)
    case unsupportedFormat(AudioFormat)
    case osStatus(Int32, String)
}

/// A capture source. PCM frames never cross this interface into SwiftUI or actors: implementations
/// copy frames into a preallocated ring that the segment writer drains on a dedicated queue.
public protocol AudioSource: AnyObject, Sendable {
    var kind: SourceKind { get }
    func start(_ configuration: AudioSourceConfiguration) throws
    func stop()
    /// Snapshot readable from any thread; updated at most a few times per second.
    func health() -> SourceHealth
    var events: AsyncStream<AudioSourceEvent> { get }
}

public enum SegmentStoreError: Error, Hashable, Sendable {
    case notStaged(AudioSegmentID)
    case checksumMismatch(AudioSegmentID)
    case io(String)
}

/// Durable segment storage (plan §6 "Writer", "Crash recovery").
public protocol SegmentStore: Sendable {
    /// Atomically publishes a staged segment. A committed index entry never points at an uncommitted file.
    func commit(_ segment: AudioSegmentRecord) throws -> AudioSegmentRecord
    func enumerateCommitted(_ meeting: MeetingID) throws -> [AudioSegmentRecord]
    /// Indexes committed files that lack rows and quarantines damaged ones.
    func recover(_ meeting: MeetingID) throws -> RecoveryReport
}

public struct RecoveryReport: Hashable, Sendable, Codable {
    public var meetingID: MeetingID
    public var reindexed: [AudioSegmentID]
    public var quarantined: [String]
    public var damagedIntervals: [SessionInterval]

    public init(meetingID: MeetingID, reindexed: [AudioSegmentID] = [], quarantined: [String] = [],
                damagedIntervals: [SessionInterval] = []) {
        self.meetingID = meetingID
        self.reindexed = reindexed
        self.quarantined = quarantined
        self.damagedIntervals = damagedIntervals
    }
}
