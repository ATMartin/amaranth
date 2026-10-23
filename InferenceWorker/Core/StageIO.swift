import CryptoKit
public import Foundation
public import Domain

/// File-based stage inputs/outputs. The scheduler writes `input.json` into a job's work directory; the worker writes
/// `output.json` there. XPC carries only the job descriptor and the output's path/hash — never meeting audio or large
/// payloads (plan §5 "Process boundaries").
public enum StageInput: Codable, Sendable {
    case prepare(PrepareInput)
    case transcribe(TranscribeInput)
    case diarize(DiarizeInput)
    case reconcile(ReconcileInput)
    case notes(NotesInput)
}

public struct NotesInput: Codable, Sendable {
    public var meetingID: MeetingID
    public var transcript: TranscriptRevision
    public var editSequence: Int
    /// Present only when the user explicitly included the scratchpad; otherwise it never leaves the app.
    public var scratchpad: ScratchpadRevision?
    public init(meetingID: MeetingID, transcript: TranscriptRevision, editSequence: Int, scratchpad: ScratchpadRevision?) {
        self.meetingID = meetingID; self.transcript = transcript; self.editSequence = editSequence; self.scratchpad = scratchpad
    }
}

public struct PrepareInput: Codable, Sendable {
    public var meetingID: MeetingID
    public var meetingDirectory: URL
    public var segments: [AudioSegmentRecord]
    public var events: [CaptureEvent]
    public init(meetingID: MeetingID, meetingDirectory: URL, segments: [AudioSegmentRecord], events: [CaptureEvent]) {
        self.meetingID = meetingID; self.meetingDirectory = meetingDirectory; self.segments = segments; self.events = events
    }
}

public struct PreparedAudio: Codable, Sendable, Hashable {
    public var directory: URL
    /// `coverage.json` content (Versioned AnalysisPreparer.Output) hash — the identity of the prepared inputs.
    public var coverageSHA256: String
    public init(directory: URL, coverageSHA256: String) { self.directory = directory; self.coverageSHA256 = coverageSHA256 }
}

public struct TranscribeInput: Codable, Sendable {
    public var meetingID: MeetingID
    public var prepared: PreparedAudio
    /// Results of processing while recording (T19), reused where identical; nil when there are none.
    public var incrementalDirectory: URL?
    public init(meetingID: MeetingID, prepared: PreparedAudio, incrementalDirectory: URL? = nil) {
        self.meetingID = meetingID; self.prepared = prepared; self.incrementalDirectory = incrementalDirectory
    }
}

public struct DiarizeInput: Codable, Sendable {
    public var meetingID: MeetingID
    public var prepared: PreparedAudio
    public var microphoneMode: MicrophoneMode
    public init(meetingID: MeetingID, prepared: PreparedAudio, microphoneMode: MicrophoneMode) {
        self.meetingID = meetingID; self.prepared = prepared; self.microphoneMode = microphoneMode
    }
}

public struct DiarizeOutput: Codable, Sendable {
    public var results: [DiarizationResult]
    /// Seconds by which system audio reappears in the mic; nil when no consistent echo was found.
    public var echoDelay: Double?
    public init(results: [DiarizationResult], echoDelay: Double?) { self.results = results; self.echoDelay = echoDelay }
}

public struct ReconcileInput: Codable, Sendable {
    public var meetingID: MeetingID
    public var asr: TranscriptRevision
    public var diarization: DiarizeOutput
    public var edits: [UserEdit]
    public var previous: TranscriptRevision?
    public var microphoneMode: MicrophoneMode
    public init(meetingID: MeetingID, asr: TranscriptRevision, diarization: DiarizeOutput, edits: [UserEdit],
                previous: TranscriptRevision?, microphoneMode: MicrophoneMode) {
        self.meetingID = meetingID; self.asr = asr; self.diarization = diarization; self.edits = edits
        self.previous = previous; self.microphoneMode = microphoneMode
    }
}

public enum StageOutput: Codable, Sendable {
    case prepared(PreparedAudio)
    case transcript(TranscriptRevision)
    case diarization(DiarizeOutput)
    case reconciled(ReconciliationResult)
    case summary(SummaryRevision)
}

public enum StageFiles {
    public static let input = "input.json"
    public static let output = "output.json"

    public static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    public static func hash(_ parts: [String]) -> String { sha256(Data(parts.joined(separator: "\u{1f}").utf8)) }

    /// Writes `value` atomically and returns its hash.
    @discardableResult
    public static func write<T: Codable & Sendable>(_ value: T, to url: URL) throws -> String {
        let data = try ContractCoding.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return sha256(data)
    }

    public static func read<T: Codable & Sendable>(_ type: T.Type, from url: URL) throws -> (T, String) {
        let data = try Data(contentsOf: url)
        return (try ContractCoding.decode(type, from: data), sha256(data))
    }
}

/// Runs one stage for a job descriptor (in the XPC worker, or in-process in tests).
public protocol JobExecutor: Sendable {
    /// Executes the job described by `job` (its work directory holds `input.json`). Returns the completion response.
    func execute(_ job: JobDescriptor, progress: @escaping @Sendable (WorkerProgress) -> Void) async throws -> WorkerResponse
    func cancel(_ job: JobID)
}

/// Classifies executor failures for retry policy.
public enum JobFailure: Error, Sendable, Equatable {
    /// The worker crashed/hung/was killed: retried automatically.
    case workerLost(String)
    /// The stage reported an error: retried once (may be transient), then failed.
    case stageFailed(String)
    /// Inputs/models missing or invalid: not retried automatically.
    case permanent(String)
}
