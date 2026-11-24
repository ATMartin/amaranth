public import Foundation

public enum ProcessingStage: String, Hashable, Sendable, Codable, CaseIterable {
    /// Normalize to 16 kHz analysis streams + VAD.
    case prepare
    case transcribe
    case diarize
    case reconcile
    case notes
    /// Provisional live transcription while recording (T14, promoted into v0).
    case live

    /// Heavy stages hold a model and are serialized (plan §10: one heavy inference stage at a time).
    public var isHeavy: Bool {
        switch self {
        case .transcribe, .diarize, .notes, .live: true
        case .prepare, .reconcile: false
        }
    }

    /// Post-meeting stage DAG.
    public var prerequisites: [ProcessingStage] {
        switch self {
        case .prepare, .live: []
        case .transcribe: [.prepare]
        case .diarize: [.prepare]
        case .reconcile: [.transcribe, .diarize]
        case .notes: [.reconcile]
        }
    }
}

public enum ProcessingState: String, Hashable, Sendable, Codable {
    case queued
    /// Deliberately suspended (active recording, thermal or memory pressure). Never shown as stuck.
    case suspended
    case running
    case succeeded
    case failed
    case cancelled

    public var isTerminal: Bool { self == .succeeded || self == .failed || self == .cancelled }

    public func canTransition(to next: ProcessingState) -> Bool {
        switch (self, next) {
        case (.queued, .running), (.queued, .suspended), (.queued, .cancelled): true
        case (.suspended, .queued), (.suspended, .cancelled): true
        case (.running, .succeeded), (.running, .failed), (.running, .cancelled): true
        // Lease expiry/worker crash or pressure: requeue or suspend from a checkpoint.
        case (.running, .queued), (.running, .suspended): true
        // Explicit retry.
        case (.failed, .queued), (.cancelled, .queued): true
        default: false
        }
    }
}

public enum SuspensionReason: String, Hashable, Sendable, Codable {
    case recordingActive, thermalPressure, memoryPressure, userPaused
    /// Capture reported missing audio or a fault while recording (T19): processing backs off to protect the recording.
    case captureFault
}

public struct JobLease: Hashable, Sendable, Codable {
    public var owner: String
    public var heartbeatAt: Date
    public var expiresAt: Date
    public init(owner: String, heartbeatAt: Date, expiresAt: Date) {
        self.owner = owner
        self.heartbeatAt = heartbeatAt
        self.expiresAt = expiresAt
    }
}

/// Opaque per-stage checkpoint (e.g. completed ASR chunk indices) committed after each completed chunk.
public struct JobCheckpoint: Hashable, Sendable, Codable {
    public var completedUnits: Int
    public var totalUnits: Int
    public var state: Data
    public init(completedUnits: Int, totalUnits: Int, state: Data = Data()) {
        self.completedUnits = completedUnits
        self.totalUnits = totalUnits
        self.state = state
    }
}

/// Content-addressed idempotency key: same inputs + same model/config/prompt ⇒ same result slot.
public struct JobKey: Hashable, Sendable, Codable, CustomStringConvertible {
    public var meetingID: MeetingID
    public var stage: ProcessingStage
    public var inputHash: String
    public var configHash: String

    public init(meetingID: MeetingID, stage: ProcessingStage, inputHash: String, configHash: String) {
        self.meetingID = meetingID
        self.stage = stage
        self.inputHash = inputHash
        self.configHash = configHash
    }

    public var description: String { "\(meetingID)/\(stage.rawValue)/\(inputHash.prefix(12))/\(configHash.prefix(12))" }
}

public struct ProcessingJob: Hashable, Sendable, Codable, Identifiable {
    public var id: JobID
    public var key: JobKey
    public var state: ProcessingState
    public var suspension: SuspensionReason?
    public var attempt: Int
    /// 0...1, monotonic within an attempt.
    public var progress: Double
    public var checkpoint: JobCheckpoint?
    /// Stable machine-readable code, e.g. "worker.crashed", "model.missing", "notes.schemaInvalid".
    public var errorCode: String?
    public var lease: JobLease?
    public var createdAt: Date
    public var updatedAt: Date
    /// Output file of a succeeded job, relative to the data root, and its hash (idempotent commit / relaunch).
    public var outputRef: String?
    public var outputSHA256: String?
    /// Earliest time a retried job may start (backoff).
    public var notBefore: Date?

    public init(id: JobID = JobID(), key: JobKey, state: ProcessingState = .queued, suspension: SuspensionReason? = nil,
                attempt: Int = 0, progress: Double = 0, checkpoint: JobCheckpoint? = nil, errorCode: String? = nil,
                lease: JobLease? = nil, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.key = key
        self.state = state
        self.suspension = suspension
        self.attempt = attempt
        self.progress = progress
        self.checkpoint = checkpoint
        self.errorCode = errorCode
        self.lease = lease
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public mutating func transition(to next: ProcessingState, at date: Date) throws {
        guard state.canTransition(to: next) else {
            throw DomainError.invariantViolated("job \(id): \(state.rawValue) → \(next.rawValue)")
        }
        if next == .running { attempt += 1 }
        if next != .suspended { suspension = nil }
        state = next
        updatedAt = date
    }
}
