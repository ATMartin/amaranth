import Foundation

/// Capture origin of audio. Identifies where audio came from, **not** who spoke.
public enum SourceKind: String, Hashable, Sendable, Codable, CaseIterable {
    case microphone
    case systemOutput
}

public enum SourceSelection: String, Hashable, Sendable, Codable, CaseIterable {
    case microphoneOnly, systemOnly, both

    public var sources: Set<SourceKind> {
        switch self {
        case .microphoneOnly: [.microphone]
        case .systemOnly: [.systemOutput]
        case .both: [.microphone, .systemOutput]
        }
    }
}

public enum SampleFormat: String, Hashable, Sendable, Codable {
    case float32
    case int16
}

/// Native stream format preserved per epoch. Mic and system formats stay separate until normalization.
public struct AudioFormat: Hashable, Sendable, Codable, CustomStringConvertible {
    public var sampleRate: Int
    public var channelCount: Int
    public var sampleFormat: SampleFormat
    public var interleaved: Bool

    public init(sampleRate: Int, channelCount: Int, sampleFormat: SampleFormat, interleaved: Bool = true) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.sampleFormat = sampleFormat
        self.interleaved = interleaved
    }

    public var bytesPerFrame: Int { channelCount * (sampleFormat == .float32 ? 4 : 2) }
    public var bytesPerSecond: Int { bytesPerFrame * sampleRate }

    /// 16 kHz mono int16 analysis derivative format (plan §7).
    public static let analysis = AudioFormat(sampleRate: 16_000, channelCount: 1, sampleFormat: .int16)

    public var description: String { "\(sampleRate)Hz/\(channelCount)ch/\(sampleFormat.rawValue)" }
}

/// Explicit capture epoch. Route/format changes, pause/resume, sleep and restarts start a new epoch.
/// Frame counters restart at zero in each epoch; `sessionStart` anchors the epoch on the session timeline.
public struct CaptureEpoch: Hashable, Sendable, Codable, Identifiable {
    public var id: EpochID
    public var meetingID: MeetingID
    public var source: SourceKind
    /// Monotonic per (meeting, source).
    public var index: Int
    public var format: AudioFormat
    public var sessionStart: SessionTime
    /// Host time (ns) of frame 0 in this epoch, for slope/offset tracking.
    public var hostTimeAtFirstFrameNanos: UInt64
    /// Opaque endpoint identifier (e.g. Core Audio device UID). Never contains speech.
    public var deviceUID: String?
    public var deviceName: String?
    public var reason: EpochStartReason

    public init(id: EpochID = EpochID(), meetingID: MeetingID, source: SourceKind, index: Int, format: AudioFormat,
                sessionStart: SessionTime, hostTimeAtFirstFrameNanos: UInt64, deviceUID: String? = nil,
                deviceName: String? = nil, reason: EpochStartReason) {
        self.id = id
        self.meetingID = meetingID
        self.source = source
        self.index = index
        self.format = format
        self.sessionStart = sessionStart
        self.hostTimeAtFirstFrameNanos = hostTimeAtFirstFrameNanos
        self.deviceUID = deviceUID
        self.deviceName = deviceName
        self.reason = reason
    }
}

public enum EpochStartReason: String, Hashable, Sendable, Codable {
    case sessionStart, resume, deviceChange, formatChange, wake, restartAfterFault
}

public enum SegmentCommitState: String, Hashable, Sendable, Codable {
    /// File written to staging; not visible to readers.
    case staged
    /// File closed, flushed, atomically renamed into the committed set and journaled.
    case committed
    /// Truncated/corrupt; kept aside, never used for processing.
    case quarantined
}

/// A short, independently recoverable PCM segment (plan §6 "Writer"). Audio is immutable once committed.
public struct AudioSegmentRecord: Hashable, Sendable, Codable, Identifiable {
    public var id: AudioSegmentID
    public var meetingID: MeetingID
    public var source: SourceKind
    public var epochID: EpochID
    /// Monotonic per (meeting, source) across epochs.
    public var sequence: Int64
    public var format: AudioFormat
    /// Index of the first frame of this segment within its epoch.
    public var firstFrameInEpoch: Int64
    public var frameCount: Int64
    public var interval: SessionInterval
    /// Relative to the meeting's audio directory.
    public var relativePath: String
    /// Lowercase hex SHA-256 of the file bytes.
    public var sha256: String
    public var state: SegmentCommitState
    /// Session time of the first frame as observed on the host clock (IOProc timestamp). `interval` is derived from
    /// the device's sample count; the difference is device-clock drift. Normalization maps frames onto this host
    /// timeline so separately clocked sources stay aligned (plan §6 "Timeline"). Original samples are never changed.
    public var observedStart: SessionTime?

    public init(id: AudioSegmentID = AudioSegmentID(), meetingID: MeetingID, source: SourceKind, epochID: EpochID,
                sequence: Int64, format: AudioFormat, firstFrameInEpoch: Int64, frameCount: Int64,
                interval: SessionInterval, relativePath: String, sha256: String, state: SegmentCommitState,
                observedStart: SessionTime? = nil) {
        self.id = id
        self.meetingID = meetingID
        self.source = source
        self.epochID = epochID
        self.sequence = sequence
        self.format = format
        self.firstFrameInEpoch = firstFrameInEpoch
        self.frameCount = frameCount
        self.interval = interval
        self.relativePath = relativePath
        self.sha256 = sha256
        self.state = state
        self.observedStart = observedStart
    }
}

public enum CaptureEventKind: String, Hashable, Sendable, Codable {
    /// Audio expected but not recorded. Distinct from recorded silence.
    case gap
    case pause
    case resume
    case deviceChange
    case formatChange
    case sleep
    case wake
    /// Realtime ring overflowed; a gap of the reported length exists.
    case overrun
    /// Source stopped delivering callbacks or commits stalled.
    case sourceFault
    case sourceRecovered
    case permissionDenied
    case diskLow
    case stoppedForDiskSpace
}

/// A discontinuity or notable capture occurrence. Never contains speech content.
public struct CaptureEvent: Hashable, Sendable, Codable, Identifiable {
    public var id: CaptureEventID
    public var meetingID: MeetingID
    /// nil for meeting-wide events (pause, sleep).
    public var source: SourceKind?
    public var interval: SessionInterval
    public var kind: CaptureEventKind
    /// Stable machine-readable reason code, e.g. "device.disconnected", "ring.overrun".
    public var reasonCode: String
    public var recoverable: Bool
    /// Estimated number of frames lost, when known.
    public var lostFrames: Int64?

    public init(id: CaptureEventID = CaptureEventID(), meetingID: MeetingID, source: SourceKind?,
                interval: SessionInterval, kind: CaptureEventKind, reasonCode: String, recoverable: Bool,
                lostFrames: Int64? = nil) {
        self.id = id
        self.meetingID = meetingID
        self.source = source
        self.interval = interval
        self.kind = kind
        self.reasonCode = reasonCode
        self.recoverable = recoverable
        self.lostFrames = lostFrames
    }

    /// Whether this event represents audio that was expected but is missing.
    public var isMissingAudio: Bool {
        switch kind {
        case .gap, .overrun, .sourceFault, .permissionDenied: true
        default: false
        }
    }
}

/// Capture lifecycle (plan §9). Independent of processing state.
public enum CaptureState: String, Hashable, Sendable, Codable {
    case idle, preparing, recording, paused, stopping, captured, capturedWithGaps, interrupted

    public var isTerminal: Bool { self == .captured || self == .capturedWithGaps || self == .interrupted }
    public var isActive: Bool { self == .preparing || self == .recording || self == .paused || self == .stopping }

    public func canTransition(to next: CaptureState) -> Bool {
        switch (self, next) {
        case (.idle, .preparing): true
        case (.preparing, .recording), (.preparing, .interrupted), (.preparing, .idle): true
        case (.recording, .paused), (.paused, .recording): true
        case (.recording, .stopping), (.paused, .stopping): true
        case (.recording, .interrupted), (.paused, .interrupted): true
        case (.stopping, .captured), (.stopping, .capturedWithGaps), (.stopping, .interrupted): true
        // Explicit resume of an interrupted session (e.g. after wake) appends a new epoch; or the user stops instead.
        case (.interrupted, .recording), (.interrupted, .stopping): true
        default: false
        }
    }
}

/// Live health of one source. Silence alone is not a fault (plan §6 "Health").
public struct SourceHealth: Hashable, Sendable, Codable {
    public enum Status: String, Hashable, Sendable, Codable {
        case inactive, starting, healthy, silent, clipping, degraded, failed, permissionDenied
    }

    public var source: SourceKind
    public var status: Status
    public var lastCallbackHostNanos: UInt64?
    public var lastCommittedSessionTime: SessionTime?
    public var peakLevelDBFS: Float?
    public var rmsLevelDBFS: Float?
    public var overrunCount: Int
    public var deviceName: String?

    public init(source: SourceKind, status: Status, lastCallbackHostNanos: UInt64? = nil,
                lastCommittedSessionTime: SessionTime? = nil, peakLevelDBFS: Float? = nil,
                rmsLevelDBFS: Float? = nil, overrunCount: Int = 0, deviceName: String? = nil) {
        self.source = source
        self.status = status
        self.lastCallbackHostNanos = lastCallbackHostNanos
        self.lastCommittedSessionTime = lastCommittedSessionTime
        self.peakLevelDBFS = peakLevelDBFS
        self.rmsLevelDBFS = rmsLevelDBFS
        self.overrunCount = overrunCount
        self.deviceName = deviceName
    }
}
