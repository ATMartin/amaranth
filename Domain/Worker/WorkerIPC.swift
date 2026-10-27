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
    /// The answer so far while an `.answer` request generates (T54): `Versioned<AnswerProgress>` JSON.
    func answerProgress(_ update: Data)
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
    /// “Ask anything” (T54): answer a question from the passages retrieved for it, with the notes model. Interactive and
    /// short; nothing is stored. Cancel with `cancel(jobID: requestID)`. Replies `.answer`.
    case answer(AnswerRequest)
}

/// One retrieved passage as the model sees it: a label (meeting, time) and its lines, already rendered as text.
public struct AnswerPassage: Hashable, Sendable, Codable {
    public var label: String
    public var text: String
    public init(label: String, text: String) { self.label = label; self.text = text }
}

/// A previous question and its answer in the same session (T55 follow-ups).
public struct AnswerTurn: Hashable, Sendable, Codable {
    public var question: String
    public var answer: String
    public init(question: String, answer: String) { self.question = question; self.answer = answer }
}

public struct AnswerRequest: Hashable, Sendable, Codable {
    public var requestID: String
    public var question: String
    /// Numbered 1… in the prompt, in this order; citations refer to these numbers.
    public var passages: [AnswerPassage]
    public var history: [AnswerTurn]
    public init(requestID: String, question: String, passages: [AnswerPassage], history: [AnswerTurn] = []) {
        self.requestID = requestID; self.question = question; self.passages = passages; self.history = history
    }
}

public struct AnswerProgress: Hashable, Sendable, Codable {
    public var requestID: String
    /// The answer text generated so far (not yet checked).
    public var partial: String
    public init(requestID: String, partial: String) { self.requestID = requestID; self.partial = partial }
}

public struct AnswerResponse: Hashable, Sendable, Codable {
    public enum Confidence: String, Hashable, Sendable, Codable { case high, medium, low }
    /// What the answer says when the passages don't support one.
    public static let refusalText = "I couldn't find that in these meetings."
    /// The checked answer; the refusal sentence when `refused`.
    public var text: String
    /// 1-based passage numbers, each one a passage of the request.
    public var citations: [Int]
    public var confidence: Confidence
    public var refused: Bool
    /// Why the checker changed the model's answer (diagnostics), if it did.
    public var checkerNote: String?
    public var promptTokens: Int
    public var generatedTokens: Int
    /// From the request arriving to the first character of answer text, and to the end.
    public var firstTextSeconds: Double?
    public var totalSeconds: Double
    /// Passages that fit the prompt budget (the first n of the request); citations are within these.
    public var passagesUsed: Int?
    public init(text: String, citations: [Int], confidence: Confidence, refused: Bool, checkerNote: String? = nil, promptTokens: Int,
                generatedTokens: Int, firstTextSeconds: Double?, totalSeconds: Double) {
        self.text = text; self.citations = citations; self.confidence = confidence; self.refused = refused; self.checkerNote = checkerNote
        self.promptTokens = promptTokens; self.generatedTokens = generatedTokens; self.firstTextSeconds = firstTextSeconds; self.totalSeconds = totalSeconds
    }
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
    /// The flush after Stop (T20): no more audio will come, so the end is padded and every word is settled.
    public var final: Bool
    public init(meetingID: MeetingID, meetingDirectory: URL, source: SourceKind, stableUntil: SessionTime, segments: [AudioSegmentRecord],
                final: Bool = false) {
        self.meetingID = meetingID; self.meetingDirectory = meetingDirectory; self.source = source
        self.stableUntil = stableUntil; self.segments = segments; self.final = final
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
    case answer(AnswerResponse)
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
