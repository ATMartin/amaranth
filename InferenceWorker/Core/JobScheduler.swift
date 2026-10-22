public import Foundation
public import Domain
public import Storage

/// Durable processing DAG per meeting (plan §9 "Jobs", T08):
///
///     prepare → { transcribe, diarize } → reconcile → notes
///
/// Notes run automatically once, for a meeting's first reconciled transcript. Later transcript or speaker changes make
/// the notes *stale* (computed by the store) instead of silently regenerating them; `enqueueNotes` regenerates.
///
/// - Jobs are rows in SQLite keyed by content (input hash + model/config hash), so enqueueing is idempotent and results
///   commit idempotently (at-least-once execution).
/// - One stage runs at a time (heavy stages hold models), except that transcription and diarization may overlap
///   (`concurrentAnalysis`, T17). Heavy stages are suspended while a recording is active and under serious thermal or
///   memory pressure; suspended jobs show as `suspended(reason)`, never as stuck.
/// - Running jobs hold a lease renewed by worker progress; on relaunch, jobs left `running` by a previous process are
///   requeued and resume from their checkpoints.
/// - Worker loss is retried with backoff; stage errors once; permanent errors are not retried automatically.
/// - Deletion tombstones the meeting, cancels its jobs, and late results are never published for it. Results whose
///   inputs are no longer current (e.g. edits changed while reconciling) are discarded and the stage re-enqueued.
public final class JobScheduler: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var asrConfigHash: String
        public var diarizationConfigHash: String
        public var reconcileConfigHash: String
        /// nil when no notes model is installed (record-only / transcript-only operation).
        public var notesConfigHash: String?
        public var microphoneMode: MicrophoneMode
        public var leaseSeconds: TimeInterval
        public var maxWorkerLossRetries: Int
        public var retryBackoff: TimeInterval
        /// T17: transcription and diarization may run at the same time (they are independent in the DAG and use
        /// different models). Every other stage still runs alone. Off restores strictly one stage at a time.
        public var concurrentAnalysis: Bool
        public init(asrConfigHash: String, diarizationConfigHash: String, reconcileConfigHash: String = "reconcile-v1",
                    notesConfigHash: String? = nil, microphoneMode: MicrophoneMode = .personal, leaseSeconds: TimeInterval = 30, maxWorkerLossRetries: Int = 3,
                    retryBackoff: TimeInterval = 2, concurrentAnalysis: Bool = true) {
            self.asrConfigHash = asrConfigHash; self.diarizationConfigHash = diarizationConfigHash
            self.reconcileConfigHash = reconcileConfigHash; self.notesConfigHash = notesConfigHash; self.microphoneMode = microphoneMode
            self.leaseSeconds = leaseSeconds; self.maxWorkerLossRetries = maxWorkerLossRetries; self.retryBackoff = retryBackoff
            self.concurrentAnalysis = concurrentAnalysis
        }
    }

    public enum Pressure: Sendable, Equatable {
        case none, recording, thermal, memory

        /// The app's policy: recording outranks thermal, which outranks memory. Serious/critical thermal state pauses
        /// heavy work; nominal/fair does not.
        public static func current(recording: Bool, thermal: ProcessInfo.ThermalState, memoryPressure: Bool) -> Pressure {
            if recording { return .recording }
            if thermal == .serious || thermal == .critical { return .thermal }
            if memoryPressure { return .memory }
            return .none
        }
    }

    public let store: MeetingStore
    public let executor: any JobExecutor
    public let configuration: Configuration
    public let owner: String
    private let pressure: @Sendable () -> Pressure
    private let lock = NSLock()
    private var loop: Task<Void, Never>?
    private var running: [JobID: (job: ProcessingJob, cancelledForPressure: Bool)] = [:]
    /// Jobs picked by the loop that have not finished (including the moment before they are marked running).
    private var active: [JobID: ProcessingStage] = [:]
    private var wake = AsyncStream<Void>.makeStream()
    /// Fires after any job state change (UI refresh, tests).
    public var onChange: (@Sendable (ProcessingJob) -> Void)?

    public init(store: MeetingStore, executor: any JobExecutor, configuration: Configuration,
                owner: String = "app-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8))",
                pressure: @escaping @Sendable () -> Pressure = { .none }) {
        self.store = store
        self.executor = executor
        self.configuration = configuration
        self.owner = owner
        self.pressure = pressure
    }

    var workRoot: URL { store.root.appending(path: "work") }

    // MARK: Lifecycle

    /// Requeues jobs left running by a previous process (their lease owner is gone) and starts the loop.
    public func start() throws {
        for var j in try store.jobs(states: [.running]) where j.lease?.owner != owner || (j.lease?.expiresAt ?? .distantPast) < Date() {
            j.state = .queued
            j.lease = nil
            j.updatedAt = Date()
            try store.upsertJob(j)
        }
        loop = Task { [weak self] in await self?.runLoop() }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        for id in lock.withLock({ Array(running.keys) }) { executor.cancel(id) }
        poke()
    }

    /// Nudges the loop (new work, pressure change).
    public func poke() { wake.continuation.yield() }

    // MARK: Public operations

    /// Enqueues processing for a captured meeting (idempotent: same committed audio → same prepare job).
    @discardableResult
    public func enqueuePipeline(_ meeting: MeetingID) throws -> ProcessingJob {
        guard try store.meeting(meeting)?.canPlayAudio == true else { throw JobFailure.permanent("audio.unavailable") }
        let segments = try store.segments(meeting)
        let events = try store.events(meeting)
        let hash = StageFiles.hash(segments.map { "\($0.id.rawValue):\($0.sha256)" } + events.map(\.id.rawValue))
        let job = try store.enqueue(ProcessingJob(key: JobKey(meetingID: meeting, stage: .prepare, inputHash: hash, configHash: "prepare-v1"),
                                                  createdAt: Date(), updatedAt: Date()))
        poke()
        return job
    }

    /// Re-runs speaker reconciliation after user edits (cheap; reuses transcript and diarization).
    public func enqueueReconcile(_ meeting: MeetingID) throws {
        try enqueueReconcileIfReady(meeting)
        poke()
    }

    /// (Re)generates notes from the meeting's current transcript, edits and (if included) scratchpad. Idempotent for
    /// unchanged inputs. Never touches user-authored notes; the previous summary stays current until this succeeds.
    @discardableResult
    public func enqueueNotes(_ meeting: MeetingID) throws -> ProcessingJob? {
        guard let config = configuration.notesConfigHash,
              let tr = try store.meeting(meeting)?.currentTranscriptRevisionID else { return nil }
        let edit = try store.edits(meeting).map(\.sequence).max() ?? 0
        let pad = try store.latestScratchpad(meeting).flatMap { $0.includeInSummary ? $0 : nil }
        let hash = StageFiles.hash([tr.rawValue, "\(edit)", pad?.id.rawValue ?? "no-scratchpad"])
        let job = try store.enqueue(ProcessingJob(key: JobKey(meetingID: meeting, stage: .notes, inputHash: hash, configHash: config),
                                                  createdAt: Date(), updatedAt: Date()))
        poke()
        return job
    }

    /// Cancels queued/running work for a meeting.
    public func cancel(_ meeting: MeetingID) throws {
        for var j in try store.jobs(meeting: meeting) where !j.state.isTerminal {
            if lock.withLock({ running[j.id] != nil }) { executor.cancel(j.id) }
            try j.transition(to: .cancelled, at: Date())
            try store.upsertJob(j)
            onChange?(j)
        }
    }

    /// Complete deletion: tombstone first (late results can no longer publish), cancel jobs, then purge every row,
    /// search entry and file for the meeting.
    public func delete(_ meeting: MeetingID) throws {
        try store.tombstone(meeting)
        try cancel(meeting)
        try store.purgeMeeting(meeting)
    }

    /// "Delete audio only": stops audio stages, then removes original audio and derivatives. Text and notes remain.
    public func deleteAudio(_ meeting: MeetingID) throws {
        for var j in try store.jobs(meeting: meeting) where !j.state.isTerminal && [.prepare, .transcribe, .diarize, .live].contains(j.key.stage) {
            if lock.withLock({ running[j.id] != nil }) { executor.cancel(j.id) }
            try j.transition(to: .cancelled, at: Date())
            j.errorCode = "audio.deleted"
            try store.upsertJob(j)
            onChange?(j)
        }
        try store.deleteAudio(meeting)
    }

    public func status(_ meeting: MeetingID) throws -> [ProcessingJob] { try store.jobs(meeting: meeting) }

    // MARK: Loop

    private func runLoop() async {
        while !Task.isCancelled {
            do {
                if let job = try nextRunnable() {
                    lock.withLock { active[job.id] = job.key.stage }
                    Task { [weak self] in
                        await self?.run(job)
                        self?.lock.withLock { _ = self?.active.removeValue(forKey: job.id) }
                        self?.poke()
                    }
                    continue
                }
            } catch {
                // Storage hiccup: back off briefly and retry.
            }
            // Idle: wait for a poke or a short timeout (backoff/pressure re-check).
            await withTaskGroup(of: Void.self) { g in
                g.addTask { [wake] in for await _ in wake.stream { return } }
                g.addTask { try? await Task.sleep(for: .milliseconds(500)) }
                await g.next()
                g.cancelAll()
            }
        }
    }

    /// Oldest queued job whose prerequisites succeeded and that may run beside the active jobs, honouring backoff and
    /// pressure.
    func nextRunnable() throws -> ProcessingJob? {
        let all = try store.jobs()
        let p = pressure()
        let busy = lock.withLock { active }
        for var j in all.filter({ $0.state == .queued || $0.state == .suspended }).sorted(by: { $0.createdAt < $1.createdAt }) {
            if busy[j.id] != nil { continue }
            if let m = try store.meeting(j.key.meetingID), m.deletedAt != nil {
                try j.transition(to: .cancelled, at: Date()); try store.upsertJob(j); continue
            }
            if let nb = j.notBefore, nb > Date() { continue }
            if j.key.stage.isHeavy, let reason = suspension(p) {
                if j.state != .suspended || j.suspension != reason {
                    if j.state == .queued { try j.transition(to: .suspended, at: Date()) }
                    j.suspension = reason
                    try store.upsertJob(j)
                    onChange?(j)
                }
                continue
            }
            // A job that cannot run beside the active ones is skipped for now. Only transcribe/diarize can overtake it, and
            // those exist only once their prepare (which runs alone) committed, so in practice this lets transcription
            // work overtake older notes, never an older reconcile.
            guard canRun(j.key.stage, beside: Array(busy.values)) else { continue }
            if j.state == .suspended { try j.transition(to: .queued, at: Date()) }
            return j
        }
        return nil
    }

    /// Transcription and diarization may overlap (one of each); every other stage runs alone.
    func canRun(_ stage: ProcessingStage, beside active: [ProcessingStage]) -> Bool {
        if active.isEmpty { return true }
        let overlapping: Set<ProcessingStage> = [.transcribe, .diarize]
        return configuration.concurrentAnalysis && overlapping.contains(stage)
            && active.allSatisfy { overlapping.contains($0) && $0 != stage }
    }

    func suspension(_ p: Pressure) -> SuspensionReason? {
        switch p {
        case .none: nil
        case .recording: .recordingActive
        case .thermal: .thermalPressure
        case .memory: .memoryPressure
        }
    }

    private func run(_ input: ProcessingJob) async {
        var job = input
        let dir = workRoot.appending(path: job.key.meetingID.rawValue).appending(path: "\(job.key.stage.rawValue)-\(job.key.inputHash.prefix(12))")
        // T16: app-side timing of this execution (written to the job directory when it ends; never affects results).
        let startedAt = Date(), t0 = ContinuousClock.now
        var writeInputSeconds = 0.0, executeSeconds = 0.0, commitSeconds = 0.0
        do {
            try writeInput(for: job, to: dir)
            writeInputSeconds = Perf.seconds(since: t0)
            try job.transition(to: .running, at: Date())
            job.lease = JobLease(owner: owner, heartbeatAt: Date(), expiresAt: Date().addingTimeInterval(configuration.leaseSeconds))
            job.errorCode = nil
            try store.upsertJob(job)
            onChange?(job)
        } catch {
            fail(&job, code: "input.\(error)", retry: false)
            return
        }
        lock.withLock { running[job.id] = (job, false) }
        // Pressure watchdog: a heavy stage is interrupted at its next checkpoint when recording starts.
        let heavy = job.key.stage.isHeavy, runningID = job.id
        let watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, heavy, self.suspension(self.pressure()) != nil else { continue }
                self.lock.withLock { self.running[runningID]?.cancelledForPressure = true }
                self.executor.cancel(runningID)
                return
            }
        }
        defer {
            watchdog.cancel(); lock.withLock { _ = running.removeValue(forKey: runningID) }
            // The meeting was deleted while this ran: remove anything the worker wrote after the purge.
            if (try? store.meeting(job.key.meetingID))??.deletedAt != nil { try? FileManager.default.removeItem(at: store.workDirectory(job.key.meetingID)) }
        }
        let descriptor = JobDescriptor(jobID: job.id, key: job.key, workDirectory: dir, checkpoint: job.checkpoint)
        let jobID = job.id
        defer {
            let timing = SchedulerTiming(stage: job.key.stage.rawValue, queuedAt: input.createdAt, startedAt: startedAt, finishedAt: Date(),
                                         writeInputSeconds: writeInputSeconds, executeSeconds: executeSeconds, commitSeconds: commitSeconds,
                                         state: job.state.rawValue, attempt: job.attempt)
            try? ContractCoding.encode(timing).write(to: dir.appending(path: SchedulerTiming.fileName), options: .atomic)
        }
        do {
            let executeStart = ContinuousClock.now
            let response = try await executor.execute(descriptor) { [weak self] p in self?.heartbeat(jobID, p) }
            executeSeconds = Perf.seconds(since: executeStart)
            job = (try store.jobs(meeting: job.key.meetingID).first { $0.id == jobID }) ?? job
            switch response {
            case .completed(_, let url, let hash):
                let commitStart = ContinuousClock.now
                defer { commitSeconds = Perf.seconds(since: commitStart) }
                try commit(&job, output: url, hash: hash)
            case .cancelled:
                if lock.withLock({ running[jobID]?.cancelledForPressure ?? false }) {
                    try job.transition(to: .suspended, at: Date())
                    job.suspension = suspension(pressure()) ?? .recordingActive
                } else if job.state != .cancelled {
                    try job.transition(to: .cancelled, at: Date())
                }
                job.lease = nil
                try store.upsertJob(job)
                onChange?(job)
            case .failed(_, let code):
                fail(&job, code: code, retry: job.attempt < 2)
            default:
                fail(&job, code: "worker.unexpectedResponse", retry: true)
            }
        } catch let f as JobFailure {
            job = (try? store.jobs(meeting: job.key.meetingID).first { $0.id == jobID }) ?? job
            switch f {
            case .workerLost(let why): fail(&job, code: "worker.lost:\(why)", retry: job.attempt <= configuration.maxWorkerLossRetries)
            case .stageFailed(let why): fail(&job, code: "stage:\(why)", retry: job.attempt < 2)
            case .permanent(let why): fail(&job, code: "permanent:\(why)", retry: false)
            }
        } catch {
            job = (try? store.jobs(meeting: job.key.meetingID).first { $0.id == jobID }) ?? job
            fail(&job, code: "worker.lost:\(error)", retry: job.attempt <= configuration.maxWorkerLossRetries)
        }
    }

    private func heartbeat(_ id: JobID, _ p: WorkerProgress) {
        guard var j = lock.withLock({ running[id]?.job }) else { return }
        j.progress = max(j.progress, p.progress)
        if let cp = p.checkpoint { j.checkpoint = cp }
        j.lease = JobLease(owner: owner, heartbeatAt: Date(), expiresAt: Date().addingTimeInterval(configuration.leaseSeconds))
        j.updatedAt = Date()
        lock.withLock { running[id]?.job = j }
        try? store.upsertJob(j)
        onChange?(j)
    }

    private func fail(_ job: inout ProcessingJob, code: String, retry: Bool) {
        if job.state == .running { try? job.transition(to: .failed, at: Date()) }
        job.errorCode = code
        job.lease = nil
        if retry, (try? job.transition(to: .queued, at: Date())) != nil {
            job.notBefore = Date().addingTimeInterval(configuration.retryBackoff * Double(max(1, job.attempt)))
        }
        try? store.upsertJob(job)
        onChange?(job)
    }

    // MARK: Inputs

    private func writeInput(for job: ProcessingJob, to dir: URL) throws {
        let m = job.key.meetingID
        let input: StageInput
        if [.prepare, .transcribe, .diarize].contains(job.key.stage), try store.meeting(m)?.canPlayAudio != true {
            throw JobFailure.permanent("audio.unavailable")
        }
        switch job.key.stage {
        case .prepare:
            input = .prepare(PrepareInput(meetingID: m, meetingDirectory: store.meetingDirectory(m),
                                          segments: try store.segments(m), events: try store.events(m)))
        case .transcribe:
            input = .transcribe(TranscribeInput(meetingID: m, prepared: try preparedAudio(m)))
        case .diarize:
            input = .diarize(DiarizeInput(meetingID: m, prepared: try preparedAudio(m), microphoneMode: configuration.microphoneMode))
        case .reconcile:
            input = .reconcile(try reconcileInput(m))
        case .notes:
            guard let m0 = try store.meeting(m), let tr = try m0.currentTranscriptRevisionID.flatMap({ try store.transcriptRevision($0) }) else {
                throw JobFailure.permanent("notes: no transcript")
            }
            let pad = try store.latestScratchpad(m).flatMap { $0.includeInSummary ? $0 : nil }
            let edits = try store.edits(m)
            // Notes read the transcript as the user sees it (text corrections applied).
            input = .notes(NotesInput(meetingID: m, transcript: tr.applyingTextCorrections(edits), editSequence: edits.map(\.sequence).max() ?? 0, scratchpad: pad))
        case .live:
            throw JobFailure.permanent("stage \(job.key.stage) not available in this milestone")
        }
        try StageFiles.write(input, to: dir.appending(path: StageFiles.input))
    }

    private func latestSucceeded(_ m: MeetingID, _ stage: ProcessingStage) throws -> ProcessingJob? {
        try store.jobs(meeting: m, states: [.succeeded]).filter { $0.key.stage == stage }.max { $0.updatedAt < $1.updatedAt }
    }

    private func output(_ job: ProcessingJob) throws -> StageOutput {
        guard let ref = job.outputRef else { throw JobFailure.permanent("no output for \(job.key)") }
        let (out, hash) = try StageFiles.read(StageOutput.self, from: store.root.appending(path: ref))
        guard hash == job.outputSHA256 else { throw JobFailure.permanent("output hash mismatch for \(job.key)") }
        return out
    }

    private func preparedAudio(_ m: MeetingID) throws -> PreparedAudio {
        guard let j = try latestSucceeded(m, .prepare), case .prepared(let p) = try output(j) else { throw JobFailure.permanent("not prepared") }
        return p
    }

    private func reconcileInput(_ m: MeetingID) throws -> ReconcileInput {
        guard let t = try latestSucceeded(m, .transcribe), case .transcript(let asr) = try output(t),
              let d = try latestSucceeded(m, .diarize), case .diarization(let diar) = try output(d) else {
            throw JobFailure.permanent("reconcile inputs missing")
        }
        let previous = try store.meeting(m)?.currentTranscriptRevisionID.flatMap { try store.transcriptRevision($0) }
        return ReconcileInput(meetingID: m, asr: asr, diarization: diar, edits: try store.edits(m),
                              previous: previous?.stage == .attributed ? previous : nil, microphoneMode: configuration.microphoneMode)
    }

    // MARK: Commit (idempotent) and DAG advance

    private func commit(_ job: inout ProcessingJob, output url: URL, hash: String) throws {
        // Verify the output the worker claims to have written.
        let (out, actual) = try StageFiles.read(StageOutput.self, from: url)
        guard actual == hash else { throw JobFailure.stageFailed("output hash mismatch") }
        let m = job.key.meetingID
        let deleted = try store.meeting(m)?.deletedAt != nil
        if deleted {
            try job.transition(to: .cancelled, at: Date()); job.lease = nil
            try store.upsertJob(job); onChange?(job)
            return
        }
        switch out {
        case .transcript(let rev):
            try store.insertTranscriptRevision(rev)
            // Until speakers are reconciled, the ASR revision is what the user sees.
            if try store.meeting(m)?.currentTranscriptRevisionID == nil { try store.publishTranscript(rev) }
        case .diarization(let d):
            for r in d.results { try store.insertDiarization(r) }
        case .reconciled(let r):
            // Stale check: if edits changed while reconciling, discard and recompute.
            let latestEdit = try store.edits(m).map(\.sequence).max() ?? 0
            // Fail closed: if the input the result was computed from cannot be read back, it is not published.
            guard let input = try? StageFiles.read(StageInput.self, from: url.deletingLastPathComponent().appending(path: StageFiles.input)),
                  case .reconcile(let used) = input.0 else {
                throw JobFailure.permanent("reconcile.inputUnreadable")
            }
            let usedEdit = used.edits.map(\.sequence).max() ?? 0
            if usedEdit < latestEdit {
                try job.transition(to: .cancelled, at: Date()); job.errorCode = "stale.edits"; job.lease = nil
                try store.upsertJob(job); onChange?(job)
                try enqueueReconcileIfReady(m)
                return
            }
            try store.publishTranscript(r.revision)
            for var e in r.editsNeedingReview { e.conflict = .needsReview; try store.appendEdit(e) }
        case .summary(let s):
            // Never replace a newer summary with an older run's result.
            if let current = try store.currentSummary(m), current.createdAt > s.createdAt {
                break
            }
            try s.validateReferences(transcript: try store.transcriptRevision(s.transcriptRevisionID)
                                         ?? { throw JobFailure.permanent("notes: transcript revision missing") }(),
                                     scratchpad: try s.scratchpadRevisionID.flatMap { try store.scratchpadRevision($0) })
            try store.publishSummary(s)
        case .prepared:
            break
        }
        try job.transition(to: .succeeded, at: Date())
        job.lease = nil
        job.progress = 1
        job.outputRef = url.path.replacingOccurrences(of: store.root.path + "/", with: "")
        job.outputSHA256 = hash
        try store.upsertJob(job)
        onChange?(job)
        try advance(after: job, output: out)
    }

    private func advance(after job: ProcessingJob, output: StageOutput) throws {
        let m = job.key.meetingID
        switch output {
        case .prepared(let p):
            try store.enqueue(ProcessingJob(key: JobKey(meetingID: m, stage: .transcribe, inputHash: p.coverageSHA256,
                                                        configHash: configuration.asrConfigHash), createdAt: Date(), updatedAt: Date()))
            try store.enqueue(ProcessingJob(key: JobKey(meetingID: m, stage: .diarize, inputHash: p.coverageSHA256,
                                                        configHash: configuration.diarizationConfigHash + ":\(configuration.microphoneMode.rawValue)"),
                                            createdAt: Date(), updatedAt: Date()))
        case .transcript, .diarization:
            try enqueueReconcileIfReady(m)
        case .reconciled:
            // First reconciled transcript → notes. Later reconciles (speaker edits) only make the notes stale.
            if try store.currentSummary(m) == nil,
               !(try store.jobs(meeting: m).contains { $0.key.stage == .notes && !$0.state.isTerminal }) {
                try enqueueNotes(m)
            }
        case .summary:
            break
        }
    }

    private func enqueueReconcileIfReady(_ m: MeetingID) throws {
        guard let t = try latestSucceeded(m, .transcribe), let d = try latestSucceeded(m, .diarize) else { return }
        let edits = try store.edits(m)
        let hash = StageFiles.hash([t.outputSHA256 ?? "", d.outputSHA256 ?? "", "\(edits.map(\.sequence).max() ?? 0)",
                                    "\(edits.count)", configuration.microphoneMode.rawValue])
        try store.enqueue(ProcessingJob(key: JobKey(meetingID: m, stage: .reconcile, inputHash: hash, configHash: configuration.reconcileConfigHash),
                                        createdAt: Date(), updatedAt: Date()))
    }
}
