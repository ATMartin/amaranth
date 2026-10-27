import CryptoKit
import Foundation
public import Domain

/// In-process fake of the inference worker for contract tests and fixture UI. The bundled XPC worker
/// hosts this same logic in T01 so real IPC/crash behavior can be exercised before models exist.
public actor FakeInferenceWorker {
    public enum Failure: Error, Equatable { case crashed, hung }

    private var injected: WorkerFault?
    private var running: [JobID: CancellationToken] = [:]
    public private(set) var completed: [JobID] = []

    public init() {}

    public func inject(_ fault: WorkerFault?) { injected = fault }

    public func handle(_ request: WorkerRequest) async throws -> WorkerResponse {
        switch request {
        case .ping:
            return .pong(pid: ProcessInfo.processInfo.processIdentifier, contractVersion: ContractVersion.current)
        case .injectFault(let f):
            injected = f
            return .acknowledged
        case .warmUp:
            return .acknowledged
        case .run(let job):
            return try await run(job, progress: { _ in })
        case .live(let r):
            // Fixture: no audio decoding; everything up to the newest committed audio becomes stable, with no words.
            let end = r.segments.map(\.interval.end).max() ?? r.stableUntil
            return .live(LiveResponse(source: r.source, stableWords: [], tentativeWords: [], stableUntil: end, processedUntil: end))
        case .incremental:
            // Fixture: accepts the segments, produces nothing.
            return .incremental(IncrementalResponse(sources: [], busy: false))
        case .answer(let r):
            // Fixture: no model; cites the first passage with its first line, or refuses without passages.
            guard let first = r.passages.first else {
                return .answer(AnswerResponse(text: AnswerResponse.refusalText, citations: [], confidence: .low, refused: true, promptTokens: 0,
                                              generatedTokens: 0, firstTextSeconds: nil, totalSeconds: 0))
            }
            return .answer(AnswerResponse(text: String(first.text.prefix(120)), citations: [1], confidence: .medium, refused: false, promptTokens: 0,
                                          generatedTokens: 0, firstTextSeconds: 0, totalSeconds: 0))
        }
    }

    public func cancel(_ id: JobID) { running[id]?.cancel() }

    /// Simulates a stage in `units` steps, reporting checkpoints, writing a small JSON result file.
    public func run(_ job: JobDescriptor, units: Int = 4,
                    progress: @Sendable (WorkerProgress) -> Void) async throws -> WorkerResponse {
        if injected == .crash { throw Failure.crashed }
        if injected == .hang { throw Failure.hung }
        let token = CancellationToken()
        running[job.jobID] = token
        defer { running[job.jobID] = nil }
        let start = job.checkpoint?.completedUnits ?? 0
        for u in start..<units {
            if token.isCancelled { return .cancelled(jobID: job.jobID) }
            try await Task.sleep(for: .milliseconds(5))
            let cp = JobCheckpoint(completedUnits: u + 1, totalUnits: units)
            progress(WorkerProgress(jobID: job.jobID, progress: Double(u + 1) / Double(units), checkpoint: cp))
        }
        let out = job.workDirectory.appending(path: "\(job.key.stage.rawValue)-result.json")
        let body = try ContractCoding.encode(["jobKey": job.key.description])
        try FileManager.default.createDirectory(at: job.workDirectory, withIntermediateDirectories: true)
        try body.write(to: out, options: .atomic)
        completed.append(job.jobID)
        return .completed(jobID: job.jobID, outputURL: out, outputSHA256: FixtureHash.sha256Hex(body))
    }
}

/// Fake pipeline adapters returning fixture data, for wiring tests before real models are integrated.
public struct FixtureTranscriber: Transcriber {
    public let producer = Fixtures.producerASR
    public init() {}
    public func transcribe(_ slice: AudioSlice, context: TranscriptionContext,
                           cancellation: CancellationToken) async throws -> TranscriptionChunkResult {
        try cancellation.check()
        let words = (Fixtures.twoSourceConversation.transcript?.allWords ?? [])
            .filter { $0.source == slice.source && slice.interval.contains($0.interval.start) }
            .map { TimedWord(text: $0.text, interval: $0.interval, quality: $0.quality) }
        return TranscriptionChunkResult(slice: slice, words: words, diagnostics: ["engine": "fixture"])
    }
}

public struct FixtureDiarizer: Diarizer {
    public let producer = Fixtures.producerDiar
    public init() {}
    public func analyze(_ input: DiarizationInput, constraints: DiarizationConstraints,
                        cancellation: CancellationToken) async throws -> DiarizationResult {
        try cancellation.check()
        var d = Fixtures.twoSourceConversation.diarization[0]
        d.meetingID = input.meetingID
        return d
    }
}

enum FixtureHash {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
