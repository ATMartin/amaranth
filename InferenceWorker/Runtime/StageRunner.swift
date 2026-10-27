public import Foundation
public import Domain
public import ProcessingCore
public import ASR
public import Diarization
public import Models
public import Notes

/// Supplies engines from verified local model files. ASR and the diarizer may be resident together (T17: transcription
/// and diarization run concurrently; together they stay under 1 GiB). The notes LLM is exclusive: loading it releases
/// both, and loading either releases it (plan §10: unload before loading the LLM).
public final class ModelProvider: @unchecked Sendable {
    public enum Error: Swift.Error { case missing(String) }
    private let lock = NSLock()
    private let resolveDirectory: @Sendable (String) throws -> (URL, String)
    private var asr: (decoders: [ParakeetASR], vads: [SileroVAD])?
    /// Instances for live text and for incremental processing (T19). Batch jobs of an earlier meeting may run while a
    /// meeting records, so neither shares a decoder with the batch pool.
    private var liveASR: ParakeetASR?
    private var incrementalASR: (ParakeetASR, SileroVAD)?
    /// Concurrent ASR decoders and VAD instances for batch transcription. Instances share the compiled Core ML models
    /// (about 5 MiB each). Alone, throughput levels off at 3 decoders on the M2 Max; beside diarization, which shares
    /// the Neural Engine, 2 finish the meeting soonest (T17, processing/0002).
    public var decoderCount = 2
    public var vadCount = 2
    private var diarizer: FluidDiarizer?
    private var notesModel: LlamaRunner?
    /// T54: a small context of its own over the notes model's weights, so an answer neither waits for a notes batch nor
    /// loads the model twice. Released with the notes model.
    private var answerModel: LlamaRunner?
    public static let answerConfiguration: LlamaRunner.Configuration = {
        // The prompt budget (2,200 tokens) plus 320 output tokens fits with room to spare (Answerer); measured +436 MB.
        var c = LlamaRunner.Configuration(); c.contextTokens = 3072; c.parallel = 1; c.kvTokens = 3072; return c
    }()
    /// Manifest ID of the notes model (the pack's summary role).
    public static let notesManifestID = "qwen3-4b-instruct-2507-q4_k_m"

    /// `resolveDirectory(manifestID)` returns the model directory and its revision.
    public init(resolveDirectory: @escaping @Sendable (String) throws -> (URL, String)) {
        self.resolveDirectory = resolveDirectory
    }

    /// Production: the active pack via `LocalModelRegistry` (sizes verified before every load, no network code).
    public static func installedPack(root: URL = ModelPackStore.defaultRoot()) -> ModelProvider {
        let registry = LocalModelRegistry(store: ModelPackStore(root: root))
        let provider = ModelProvider { id in
            let r = try registry.resolve(ModelManifestID(id))
            return (r.rootURL, r.manifest.sourceRevision)
        }
        // Developer override for measurement (`defaults write com.alexmartin.amaranth asrDecoders -int N`); no UI.
        if let n = UserDefaults(suiteName: "com.alexmartin.amaranth")?.integer(forKey: "asrDecoders"), n > 0 { provider.decoderCount = n }
        return provider
    }

    /// Development/tests: a `ModelStore/` directory laid out by manifest ID.
    public static func directory(_ root: URL) -> ModelProvider {
        ModelProvider { id in
            let dir = root.appending(path: id)
            guard FileManager.default.fileExists(atPath: dir.path) else { throw Error.missing(id) }
            return (dir, "local")
        }
    }

    /// The first decoder and VAD (single-instance callers).
    public func transcription() throws -> (ParakeetASR, SileroVAD) {
        let pool = try transcriptionPool()
        return (pool.decoders[0], pool.vads[0])
    }

    /// Live text's own decoder.
    public func live() throws -> ParakeetASR {
        try lock.withLock {
            if let liveASR { return liveASR }
            notesModel = nil; answerModel = nil
            let (dir, rev) = try resolveDirectory("parakeet-tdt-0.6b-v3-coreml")
            let d = try Perf.measure("model.load.asr") { try ParakeetASR(directory: dir, manifestID: ModelManifestID("parakeet-tdt-0.6b-v3-coreml"), revision: rev) }
            liveASR = d
            return d
        }
    }

    /// Incremental processing's own decoder and VAD.
    public func incremental() throws -> (ParakeetASR, SileroVAD) {
        try lock.withLock {
            if let incrementalASR { return incrementalASR }
            notesModel = nil; answerModel = nil
            let (dir, rev) = try resolveDirectory("parakeet-tdt-0.6b-v3-coreml")
            let (vadDir, _) = try resolveDirectory("silero-vad-coreml")
            let e = try Perf.measure("model.load.asr") {
                (try ParakeetASR(directory: dir, manifestID: ModelManifestID("parakeet-tdt-0.6b-v3-coreml"), revision: rev),
                 try SileroVAD(modelFile: vadDir.appending(path: "silero-vad-unified-256ms-v6.2.1.mlmodelc")))
            }
            incrementalASR = e
            return e
        }
    }

    public func transcriptionPool() throws -> (decoders: [ParakeetASR], vads: [SileroVAD]) {
        try lock.withLock {
            if let asr { return asr }
            notesModel = nil; answerModel = nil
            let (dir, rev) = try resolveDirectory("parakeet-tdt-0.6b-v3-coreml")
            let (vadDir, _) = try resolveDirectory("silero-vad-coreml")
            let pool = try Perf.measure("model.load.asr") {
                (decoders: try (0..<max(1, decoderCount)).map { _ in
                    try ParakeetASR(directory: dir, manifestID: ModelManifestID("parakeet-tdt-0.6b-v3-coreml"), revision: rev) },
                 vads: try (0..<max(1, vadCount)).map { _ in
                    try SileroVAD(modelFile: vadDir.appending(path: "silero-vad-unified-256ms-v6.2.1.mlmodelc")) })
            }
            asr = pool
            return pool
        }
    }

    public func diarization() throws -> FluidDiarizer {
        try lock.withLock {
            if let diarizer { return diarizer }
            notesModel = nil; answerModel = nil
            let (dir, rev) = try resolveDirectory("speaker-diarization-coreml")
            let d = try Perf.measure("model.load.diarization") {
                try FluidDiarizer(directory: dir, manifestID: ModelManifestID("speaker-diarization-coreml"), revision: rev)
            }
            diarizer = d
            return d
        }
    }

    /// The notes LLM. ASR and diarization are released first (plan §10: unload before loading the LLM).
    public func notes() throws -> LlamaRunner {
        try lock.withLock {
            if let notesModel { return notesModel }
            asr = nil; diarizer = nil; liveASR = nil; incrementalASR = nil
            let (dir, rev) = try resolveDirectory(Self.notesManifestID)
            guard let gguf = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "gguf" }) else { throw Error.missing("\(Self.notesManifestID) gguf") }
            let r = try Perf.measure("model.load.notes") { try LlamaRunner(gguf: gguf, manifestID: ModelManifestID(Self.notesManifestID), revision: rev) }
            notesModel = r
            return r
        }
    }

    /// The answer context (T54). Loads the notes model first if needed, which releases ASR and diarization: the app
    /// only asks while no recording or transcript work is active.
    public func answers() throws -> LlamaRunner {
        let notes = try notes()
        return try lock.withLock {
            if let answerModel { return answerModel }
            let r = try Perf.measure("model.load.answers") { try LlamaRunner(sharing: notes, configuration: Self.answerConfiguration) }
            answerModel = r
            return r
        }
    }

    public func unloadAll() { lock.withLock { asr = nil; diarizer = nil; notesModel = nil; answerModel = nil; liveASR = nil; incrementalASR = nil } }
}

/// Executes one stage from `input.json` in the job's work directory and writes `output.json` (atomically).
public final class StageRunner: @unchecked Sendable {
    let models: ModelProvider

    public init(models: ModelProvider) { self.models = models }

    /// Provisional live text (T14). Uses the same ASR model as transcription (loading it releases the notes LLM).
    public func live(_ r: LiveRequest) async throws -> LiveResponse {
        try await LiveTranscriber(asr: try models.live()).process(r)
    }

    private let incrementalLock = NSLock()
    private var incrementalSessions: [MeetingID: (transcriber: IncrementalTranscriber, token: CancellationToken)] = [:]

    /// Final-quality transcription while recording (T19). State is kept per meeting until `close`; a new worker starts
    /// over from the segments the app resends (window checkpoints on disk are reused when identical).
    public func incremental(_ r: IncrementalRequest) async throws -> IncrementalResponse {
        if r.close {
            incrementalLock.withLock { incrementalSessions.removeValue(forKey: r.meetingID)?.token.cancel() }
            return IncrementalResponse(sources: [], busy: false)
        }
        let session = try incrementalLock.withLock {
            if let s = incrementalSessions[r.meetingID] { return s }
            let (decoder, vad) = try models.incremental()
            let s = (transcriber: try IncrementalTranscriber(meetingDirectory: r.meetingDirectory, directory: r.workDirectory, decoder: decoder, vad: vad),
                     token: CancellationToken())
            incrementalSessions[r.meetingID] = s
            return s
        }
        let trace = PerfTrace()
        guard let p = try await PerfTrace.$current.withValue(trace, operation: {
            try await session.transcriber.advance(segments: r.segments, events: r.events, deadline: .now + .seconds(r.budgetSeconds),
                                                  cancellation: session.token)
        }) else { return IncrementalResponse(sources: [], busy: true) }
        return IncrementalResponse(sources: p.sources.map { s in
            IncrementalResponse.Source(source: s.source, lastSequence: s.lastSequence, settledUntil: s.settledUntil, finalizedUntil: s.finalizedUntil,
                                       plannedWindows: s.plannedWindows, decodedWindows: s.decodedWindows, newWords: s.newWords.map { w in
                Word(id: WordID("final-\(s.source.rawValue)-\(Int(w.start * 1000))"), text: w.text, interval: .seconds(w.start, max(w.end, w.start + 0.01)),
                     source: s.source, quality: ASRQuality(engine: "parakeet-tdt-0.6b-v3", values: ["tokenConfidenceMean": w.tokenConfidence]))
            })
        }, busy: false)
    }

    /// “Ask anything” (T54): answers from the request's passages with the notes model; `onPartial` gets the answer so far.
    public func answer(_ r: AnswerRequest, cancellation: CancellationToken, onPartial: @escaping (String) -> Void) throws -> AnswerResponse {
        try Answerer.answer(r, generator: try models.answers(), cancellation: cancellation, onPartial: onPartial)
    }

    /// Loads (and so compiles, on first use on this Mac) the transcription and diarization models.
    public func warmUp() throws {
        _ = try Perf.measure("model.warmUp") { try models.transcriptionPool(); try models.diarization() }
    }

    /// Process start, for the worker age recorded in `timing.json` (cold vs warm).
    static let processStart = Date()

    /// Runs the stage under a fresh `PerfTrace` and writes `timing.json` beside the output (T16). Timing is best-effort
    /// and never affects the stage result.
    public func run(_ job: JobDescriptor, cancellation: CancellationToken,
                    progress: @escaping @Sendable (WorkerProgress) -> Void) async throws -> WorkerResponse {
        let trace = PerfTrace(), t0 = ContinuousClock.now, started = Date()
        let thermal = ProcessInfo.processInfo.thermalState.label
        let response = try await PerfTrace.$current.withValue(trace) { try await runStage(job, cancellation: cancellation, progress: progress) }
        let timing = StageTiming(stage: job.key.stage.rawValue, wallSeconds: Perf.seconds(since: t0), trace: trace.snapshot,
                                 workerPID: getpid(), workerUptimeSeconds: started.timeIntervalSince(Self.processStart),
                                 qos: Self.qosLabel(), thermalStart: thermal, thermalEnd: ProcessInfo.processInfo.thermalState.label,
                                 build: _isDebugAssertConfiguration() ? "debug" : "release")
        try? ContractCoding.encode(timing).write(to: job.workDirectory.appending(path: StageTiming.fileName), options: .atomic)
        return response
    }

    static func qosLabel() -> String {
        switch qos_class_self() {
        case QOS_CLASS_USER_INTERACTIVE: "userInteractive"
        case QOS_CLASS_USER_INITIATED: "userInitiated"
        case QOS_CLASS_DEFAULT: "default"
        case QOS_CLASS_UTILITY: "utility"
        case QOS_CLASS_BACKGROUND: "background"
        default: "unspecified"
        }
    }

    func runStage(_ job: JobDescriptor, cancellation: CancellationToken,
                  progress: @escaping @Sendable (WorkerProgress) -> Void) async throws -> WorkerResponse {
        let (input, _) = try Perf.measure("stage.readInput") { try StageFiles.read(StageInput.self, from: job.workDirectory.appending(path: StageFiles.input)) }
        let output: StageOutput
        switch input {
        case .prepare(let i):
            let dir = job.workDirectory.appending(path: "prepared")
            _ = try Perf.measure("prepare.total") { try AnalysisPreparer.prepare(meetingDirectory: i.meetingDirectory, segments: i.segments, events: i.events,
                                             outputDirectory: dir, cancellation: cancellation) }
            let cov = try Data(contentsOf: dir.appending(path: "coverage.json"))
            output = .prepared(PreparedAudio(directory: dir, coverageSHA256: StageFiles.sha256(cov)))
        case .transcribe(let i):
            let pool = try models.transcriptionPool()
            let prepared = try ContractCoding.decode(AnalysisPreparer.Output.self,
                                                     from: Data(contentsOf: i.prepared.directory.appending(path: "coverage.json")))
            let pipeline = TranscriptionPipeline(decoders: pool.decoders, vads: pool.vads, workDirectory: job.workDirectory.appending(path: "windows"),
                                                 incremental: i.incrementalDirectory)
            let rev = try await pipeline.run(meetingID: i.meetingID, prepared: prepared, preparedDirectory: i.prepared.directory,
                                             cancellation: cancellation) { p, cp in
                progress(WorkerProgress(jobID: job.jobID, progress: p, checkpoint: cp))
            }
            output = .transcript(rev)
        case .diarize(let i):
            let diarizer = try models.diarization()
            let prepared = try ContractCoding.decode(AnalysisPreparer.Output.self,
                                                     from: Data(contentsOf: i.prepared.directory.appending(path: "coverage.json")))
            var results: [DiarizationResult] = []
            // Online calls: diarize the system track; in room mode also the mic (a mic may carry several people).
            let sources = prepared.coverage.filter { $0.source == .systemOutput || i.microphoneMode == .room }
            for (n, cov) in sources.enumerated() {
                try cancellation.check()
                let audio = AnalysisAudio(url: i.prepared.directory.appending(path: cov.derivativeFile))
                let done = Double(n) / Double(max(1, sources.count))
                results.append(try await diarizer.analyze(meetingID: i.meetingID, source: cov.source, audio: audio, cancellation: cancellation) {
                    progress(WorkerProgress(jobID: job.jobID, progress: done, checkpoint: JobCheckpoint(completedUnits: n, totalUnits: sources.count)))
                })
                progress(WorkerProgress(jobID: job.jobID, progress: Double(n + 1) / Double(max(1, sources.count)),
                                        checkpoint: JobCheckpoint(completedUnits: n + 1, totalUnits: sources.count)))
            }
            var echo: Double?
            if let mic = prepared.coverage.first(where: { $0.source == .microphone }),
               let sys = prepared.coverage.first(where: { $0.source == .systemOutput }) {
                echo = try Perf.measure("diarize.echo") { try EchoAnalyzer.estimateDelay(mic: AnalysisAudio(url: i.prepared.directory.appending(path: mic.derivativeFile)),
                                                      system: AnalysisAudio(url: i.prepared.directory.appending(path: sys.derivativeFile))) }
            }
            output = .diarization(DiarizeOutput(results: results, echoDelay: echo))
        case .notes(let i):
            let generator = try models.notes()
            let pipeline = NotesPipeline(generator: generator, workDirectory: job.workDirectory.appending(path: "notes"))
            let rev = try pipeline.run(meetingID: i.meetingID, transcript: i.transcript, editSequence: i.editSequence,
                                       scratchpad: i.scratchpad, cancellation: cancellation) { p in
                progress(WorkerProgress(jobID: job.jobID, progress: p, checkpoint: nil))
            }
            output = .summary(rev)
        case .reconcile(let i):
            let reconciler = MeetingReconciler(microphoneMode: i.microphoneMode, echoDelay: i.diarization.echoDelay, previous: i.previous)
            output = .reconciled(try reconciler.combine(i.asr, diarization: i.diarization.results, sourceMap: SourceMap(epochs: [], events: []),
                                                        edits: i.edits))
        }
        let url = job.workDirectory.appending(path: StageFiles.output)
        let hash = try Perf.measure("stage.writeOutput") { try StageFiles.write(output, to: url) }
        return .completed(jobID: job.jobID, outputURL: url, outputSHA256: hash)
    }
}

/// Runs stages in-process (tests; also a fallback for development). Production uses the XPC worker.
public final class InProcessExecutor: JobExecutor, @unchecked Sendable {
    let runner: StageRunner
    private let lock = NSLock()
    private var tokens: [JobID: CancellationToken] = [:]
    /// Test hook: fail the next N executions as if the worker had crashed.
    public var simulateWorkerLoss = 0

    public init(runner: StageRunner) { self.runner = runner }

    public func execute(_ job: JobDescriptor, progress: @escaping @Sendable (WorkerProgress) -> Void) async throws -> WorkerResponse {
        if lock.withLock({ () -> Bool in defer { if simulateWorkerLoss > 0 { simulateWorkerLoss -= 1 } }; return simulateWorkerLoss > 0 }) {
            throw JobFailure.workerLost("simulated crash")
        }
        let token = CancellationToken()
        lock.withLock { tokens[job.jobID] = token }
        defer { lock.withLock { tokens[job.jobID] = nil } }
        do {
            return try await runner.run(job, cancellation: token, progress: progress)
        } catch is CancellationError {
            return .cancelled(jobID: job.jobID)
        }
    }

    public func cancel(_ job: JobID) { lock.withLock { tokens[job]?.cancel() } }
}
