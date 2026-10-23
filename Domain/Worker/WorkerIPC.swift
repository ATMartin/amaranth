public import Foundation

/// Mach service / bundle identifier of the bundled XPC inference worker. Frozen (T01).
public enum WorkerIdentity {
    public static let appBundleID = "com.alexmartin.amaranth"
    public static let workerBundleID = "com.alexmartin.amaranth.InferenceWorker"
}

/// XPC payloads are bounded: job metadata, bounded results or file references — never a meeting's PCM.
public enum WorkerIPCLimits {
    public static let maxMessageBytes = 1 * 1024 * 1024
}

/// NSXPC interface exported by the worker. Payloads are `Versioned<WorkerRequest>` / `Versioned<WorkerResponse>` JSON.
@objc(AMRInferenceWorkerXPC)
public protocol InferenceWorkerXPC {
    func send(_ request: Data, reply: @escaping @Sendable (Data?, NSError?) -> Void)
    func cancel(jobID: String)
}

/// NSXPC interface exported by the app so the worker can stream progress.
@objc(AMRInferenceWorkerClientXPC)
public protocol InferenceWorkerClientXPC {
    func progress(_ update: Data)
}

public struct JobDescriptor: Hashable, Sendable, Codable {
    public var jobID: JobID
    public var key: JobKey
    /// Directory the worker may read inputs from and write outputs to (file references, not payloads).
    public var workDirectory: URL
    public var checkpoint: JobCheckpoint?
    public var modelManifestIDs: [ModelManifestID]

    public init(jobID: JobID, key: JobKey, workDirectory: URL, checkpoint: JobCheckpoint? = nil,
                modelManifestIDs: [ModelManifestID] = []) {
        self.jobID = jobID
        self.key = key
        self.workDirectory = workDirectory
        self.checkpoint = checkpoint
        self.modelManifestIDs = modelManifestIDs
    }
}

public enum WorkerRequest: Hashable, Sendable, Codable {
    case ping
    case run(JobDescriptor)
    /// Test-only fault injection; ignored unless the worker was launched with fault injection enabled.
    case injectFault(WorkerFault)
    /// Provisional live text for newly committed audio of one source (T14). Stateless: the request carries everything.
    case live(LiveRequest)
    /// Loads the transcription and diarization models so Core ML compiles them for this Mac now, not on the first job
    /// (tracked item 3; sent after a model pack is installed). Replies `acknowledged`.
    case warmUp
    /// Final-quality transcription while recording (T19). Carries segments committed since the worker's last reply;
    /// the worker keeps per-meeting state, works for up to `budgetSeconds`, and replies `.incremental`.
    case incremental(IncrementalRequest)
}

/// Incremental processing input. Only durable (committed) audio is read; capture is never touched.
public struct IncrementalRequest: Hashable, Sendable, Codable {
    public var meetingID: MeetingID
    public var meetingDirectory: URL
    /// The meeting's incremental work directory (read again by the transcription stage at Stop).
    public var workDirectory: URL
    /// Committed segments after each source's `lastSequence` in the previous reply (all of them for a new worker).
    public var segments: [AudioSegmentRecord]
    public var events: [CaptureEvent]
    public var budgetSeconds: Double
    /// Stop: cancel any work in progress for this meeting and release its state.
    public var close: Bool
    public init(meetingID: MeetingID, meetingDirectory: URL, workDirectory: URL, segments: [AudioSegmentRecord], events: [CaptureEvent],
                budgetSeconds: Double, close: Bool = false) {
        self.meetingID = meetingID; self.meetingDirectory = meetingDirectory; self.workDirectory = workDirectory
        self.segments = segments; self.events = events; self.budgetSeconds = budgetSeconds; self.close = close
    }
}

public struct IncrementalResponse: Hashable, Sendable, Codable {
    public struct Source: Hashable, Sendable, Codable {
        public var source: SourceKind
        /// Highest segment sequence the worker has; the next request sends later ones.
        public var lastSequence: Int64?
        /// Settled audio, and the end of the final-quality text so far (seconds).
        public var settledUntil: Double
        public var finalizedUntil: Double
        public var plannedWindows: Int
        public var decodedWindows: Int
        /// Final-quality words that became available in this call (they replace live text before `finalizedUntil`).
        public var newWords: [Word]
        public init(source: SourceKind, lastSequence: Int64?, settledUntil: Double, finalizedUntil: Double, plannedWindows: Int,
                    decodedWindows: Int, newWords: [Word]) {
            self.source = source; self.lastSequence = lastSequence; self.settledUntil = settledUntil; self.finalizedUntil = finalizedUntil
            self.plannedWindows = plannedWindows; self.decodedWindows = decodedWindows; self.newWords = newWords
        }
    }
    public var sources: [Source]
    /// Another call for this meeting was still running; nothing was done.
    public var busy: Bool
    public init(sources: [Source], busy: Bool) { self.sources = sources; self.busy = busy }
}

/// Live text input: committed segments of one source from shortly before `stableUntil`, plus that stable point.
/// Only durable (committed) audio is ever read; capture is never touched.
public struct LiveRequest: Hashable, Sendable, Codable {
    public var meetingID: MeetingID
    public var meetingDirectory: URL
    public var source: SourceKind
    /// Words before this session time are already settled; the worker re-decodes from here (with context).
    public var stableUntil: SessionTime
    public var segments: [AudioSegmentRecord]
    public init(meetingID: MeetingID, meetingDirectory: URL, source: SourceKind, stableUntil: SessionTime, segments: [AudioSegmentRecord]) {
        self.meetingID = meetingID; self.meetingDirectory = meetingDirectory; self.source = source
        self.stableUntil = stableUntil; self.segments = segments
    }
}

public struct LiveResponse: Hashable, Sendable, Codable {
    public var source: SourceKind
    /// Words that will not change in later live passes (they are still provisional versus the final transcript).
    public var stableWords: [Word]
    /// Words after the new stable point; the next pass replaces them.
    public var tentativeWords: [Word]
    public var stableUntil: SessionTime
    /// End of the audio this pass saw.
    public var processedUntil: SessionTime
    public init(source: SourceKind, stableWords: [Word], tentativeWords: [Word], stableUntil: SessionTime, processedUntil: SessionTime) {
        self.source = source; self.stableWords = stableWords; self.tentativeWords = tentativeWords
        self.stableUntil = stableUntil; self.processedUntil = processedUntil
    }
}

public enum WorkerFault: String, Hashable, Sendable, Codable {
    case crash, hang
    /// The next job the worker runs stops reporting progress and never completes (Debug builds only).
    case stallNextJob
}

public struct WorkerProgress: Hashable, Sendable, Codable {
    public var jobID: JobID
    public var progress: Double
    public var checkpoint: JobCheckpoint?
    public init(jobID: JobID, progress: Double, checkpoint: JobCheckpoint?) {
        self.jobID = jobID
        self.progress = progress
        self.checkpoint = checkpoint
    }
}

public enum WorkerResponse: Hashable, Sendable, Codable {
    case pong(pid: Int32, contractVersion: Int)
    /// Result written to `outputURL` inside the job's work directory; hash allows idempotent commit.
    case completed(jobID: JobID, outputURL: URL, outputSHA256: String)
    case failed(jobID: JobID, errorCode: String)
    case cancelled(jobID: JobID)
    case acknowledged
    case live(LiveResponse)
    case incremental(IncrementalResponse)
}

public enum WorkerIPCCodec {
    public static func encode<T: Codable & Sendable>(_ value: T) throws -> Data {
        let data = try ContractCoding.encode(value)
        guard data.count <= WorkerIPCLimits.maxMessageBytes else {
            throw DomainError.invariantViolated("XPC message \(data.count) bytes exceeds limit")
        }
        return data
    }

    public static func decode<T: Codable & Sendable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= WorkerIPCLimits.maxMessageBytes else {
            throw DomainError.invariantViolated("XPC message \(data.count) bytes exceeds limit")
        }
        return try ContractCoding.decode(type, from: data)
    }
}
