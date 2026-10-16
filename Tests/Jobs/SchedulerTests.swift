import Foundation
import Testing
@testable import ProcessingCore
@testable import ProcessingRuntime
import Capture
import Domain
import Storage

/// Fast executor: synthetic outputs per stage, controllable timing; reconcile uses the real (pure) reconciler.
final class FakeExecutor: JobExecutor, @unchecked Sendable {
    let lock = NSLock()
    var delay: Duration = .milliseconds(30)
    var workerLossesRemaining = 0
    var executed: [ProcessingStage] = []
    var gate: [ProcessingStage: AsyncStream<Void>] = [:]   // stage waits for a signal when present
    var tokens: [JobID: Bool] = [:]
    var failing: [MeetingID: ProcessingStage] = [:]   // stage reports a permanent error for that meeting
    var coldStartDelay: Duration = .zero              // first job pays a model-load cost
    let reconcileRunner = StageRunner(models: ModelProvider { _ in throw ModelProvider.Error.missing("unused") })

    func execute(_ job: JobDescriptor, progress: @escaping @Sendable (WorkerProgress) -> Void) async throws -> WorkerResponse {
        let lost = lock.withLock { () -> Bool in defer { if workerLossesRemaining > 0 { workerLossesRemaining -= 1 } }; return workerLossesRemaining > 0 }
        if lost { throw JobFailure.workerLost("simulated") }
        let (cold, fails) = lock.withLock { () -> (Duration, Bool) in
            executed.append(job.key.stage); tokens[job.jobID] = false
            defer { coldStartDelay = .zero }
            return (coldStartDelay, failing[job.key.meetingID] == job.key.stage)
        }
        if cold > .zero { try await Task.sleep(for: cold) }
        if fails { throw JobFailure.permanent("simulated stage failure") }
        if job.key.stage != .reconcile, let g = lock.withLock({ gate[job.key.stage] }) { for await _ in g { break } }
        for i in 1...4 {
            try await Task.sleep(for: delay / 4)
            if lock.withLock({ tokens[job.jobID] == true }) { return .cancelled(jobID: job.jobID) }
            progress(WorkerProgress(jobID: job.jobID, progress: Double(i) / 4, checkpoint: JobCheckpoint(completedUnits: i, totalUnits: 4)))
        }
        let (input, _) = try StageFiles.read(StageInput.self, from: job.workDirectory.appending(path: StageFiles.input))
        let out: StageOutput
        let producer = ProducerInfo(component: "fake", configHash: "f")
        switch input {
        case .prepare:
            let cov = job.workDirectory.appending(path: "prepared/coverage.json")
            let h = try StageFiles.write(["fake"], to: cov)
            out = .prepared(PreparedAudio(directory: cov.deletingLastPathComponent(), coverageSHA256: h))
        case .transcribe(let i):
            let words = (0..<6).map { Word(id: WordID("w\($0)"), text: "word\($0)", interval: .seconds(Double($0), Double($0) + 0.5), source: .systemOutput) }
            out = .transcript(TranscriptRevision(meetingID: i.meetingID, kind: .final, stage: .asr, createdAt: Date(), producer: producer,
                                                 segments: [TranscriptSegment(id: TranscriptSegmentID("s0"), source: .systemOutput,
                                                                              interval: .seconds(0, 5.5), words: words)],
                                                 coverage: []))
        case .diarize(let i):
            out = .diarization(DiarizeOutput(results: [DiarizationResult(meetingID: i.meetingID, source: .systemOutput, producer: producer,
                clusters: [ClusterID("a"), ClusterID("b")],
                turns: [SpeakerTurn(interval: .seconds(0, 3), source: .systemOutput, cluster: ClusterID("a")),
                        SpeakerTurn(interval: .seconds(3, 6), source: .systemOutput, cluster: ClusterID("b"))], overlaps: [])], echoDelay: nil))
        case .notes(let i):
            guard let seg = i.transcript.segments.first, let a = seg.words.first, let b = seg.words.last else { throw JobFailure.permanent("empty") }
            let ev = EvidenceRef.transcript(TranscriptEvidence(revisionID: i.transcript.id, segmentID: seg.id, firstWord: a.id, lastWord: b.id))
            out = .summary(SummaryRevision(meetingID: i.meetingID, transcriptRevisionID: i.transcript.id, editSequence: i.editSequence,
                                           createdAt: Date(), producer: producer, promptVersion: "fake",
                                           content: SummaryContent(decisions: [SummaryItem(kind: .decision, text: "fake decision", evidence: [ev])]),
                                           validation: SummaryValidationReport(status: .valid)))
        case .reconcile:
            if let g = lock.withLock({ gate[.reconcile] }) { for await _ in g { break } }
            return try await reconcileRunner.run(job, cancellation: CancellationToken(), progress: progress)
        }
        let url = job.workDirectory.appending(path: StageFiles.output)
        let hash = try StageFiles.write(out, to: url)
        return .completed(jobID: job.jobID, outputURL: url, outputSHA256: hash)
    }

    func cancel(_ job: JobID) { lock.withLock { tokens[job] = true } }
}

final class PressureBox: @unchecked Sendable {
    private let lock = NSLock(); private var v: JobScheduler.Pressure = .none
    var value: JobScheduler.Pressure { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
}

enum JobFixture {
    static func storeWithMeeting() throws -> (MeetingStore, MeetingID, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "amr-jobs-\(UUID())")
        let store = try MeetingStore(root: root)
        let m = MeetingID()
        try store.upsertMeeting(Meeting(id: m, title: "t", createdAt: Date(), captureState: .captured))
        let seg = AudioSegmentRecord(meetingID: m, source: .systemOutput, epochID: EpochID(), sequence: 0,
                                     format: AudioFormat(sampleRate: 16_000, channelCount: 1, sampleFormat: .float32), firstFrameInEpoch: 0,
                                     frameCount: 32_000, interval: .seconds(0, 2), relativePath: "x.caf", sha256: String(repeating: "a", count: 64), state: .committed)
        try store.insertSegments([seg])
        return (store, m, root)
    }

    static func config() -> JobScheduler.Configuration {
        JobScheduler.Configuration(asrConfigHash: "asr", diarizationConfigHash: "diar", retryBackoff: 0.05)
    }

    static func wait(_ timeout: Duration = .seconds(10), until cond: () throws -> Bool) async rethrows -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline { if try cond() { return true }; try? await Task.sleep(for: .milliseconds(25)) }
        return try cond()
    }
}

@Suite("Job scheduler", .serialized)
struct SchedulerTests {
    @Test func runsTheDAGOnceAndPublishesAnAttributedTranscript() async throws {
        let (store, m, root) = try JobFixture.storeWithMeeting()
        defer { try? FileManager.default.removeItem(at: root) }
        let exec = FakeExecutor()
        let s = JobScheduler(store: store, executor: exec, configuration: JobFixture.config())
        try s.start()
        defer { s.stop() }
        let a = try s.enqueuePipeline(m), b = try s.enqueuePipeline(m)
        #expect(a.id == b.id, "enqueue is idempotent by content key")
        #expect(try await JobFixture.wait { try store.jobs(meeting: m).filter { $0.key.stage == .reconcile && $0.state == .succeeded }.count == 1 })
        let order = exec.lock.withLock { exec.executed }
        #expect(order.first == .prepare && order.last == .reconcile && order.count == 4)
        let rev = try #require(try store.meeting(m)?.currentTranscriptRevisionID.flatMap { try store.transcriptRevision($0) })
        #expect(rev.stage == .attributed && rev.speakers.count == 2)
        #expect(try store.transcriptRevisions(m).count == 2, "asr + attributed; no duplicates")
    }

    @Test func heavyStagesWaitWhileRecordingAndShowSuspended() async throws {
        let (store, m, root) = try JobFixture.storeWithMeeting()
        defer { try? FileManager.default.removeItem(at: root) }
        let pressure = PressureBox()
        pressure.value = .recording
        let s = JobScheduler(store: store, executor: FakeExecutor(), configuration: JobFixture.config(), pressure: { pressure.value })
        try s.start()
        defer { s.stop() }
        try s.enqueuePipeline(m)
        // Prepare (not heavy) runs; transcribe/diarize are suspended with a reason, not stuck.
        #expect(try await JobFixture.wait { try store.jobs(meeting: m).filter { $0.state == .suspended }.count == 2 })
        let suspended = try store.jobs(meeting: m).filter { $0.state == .suspended }
        #expect(suspended.allSatisfy { $0.suspension == .recordingActive && $0.key.stage.isHeavy })
        #expect(MeetingStatus(meeting: try store.meeting(m)!, jobs: try store.jobs(meeting: m), events: []).processing == .waiting(.recordingActive))
        pressure.value = .none
        s.poke()
        #expect(try await JobFixture.wait { try store.jobs(meeting: m).contains { $0.key.stage == .reconcile && $0.state == .succeeded } })
    }

    @Test func runningHeavyStageYieldsWhenRecordingStartsAndResumesAfter() async throws {
        let (store, m, root) = try JobFixture.storeWithMeeting()
        defer { try? FileManager.default.removeItem(at: root) }
        let exec = FakeExecutor()
        exec.delay = .seconds(3)   // long enough to be mid-stage when recording starts
        let pressure = PressureBox()
        let s = JobScheduler(store: store, executor: exec, configuration: JobFixture.config(), pressure: { pressure.value })
        try s.start()
        defer { s.stop() }
        try s.enqueuePipeline(m)
        #expect(try await JobFixture.wait { try store.jobs(meeting: m).contains { $0.key.stage.isHeavy && $0.state == .running } })
        let running = try #require(try store.jobs(meeting: m).first { $0.key.stage.isHeavy && $0.state == .running })
        pressure.value = .recording
        #expect(try await JobFixture.wait(.seconds(3)) {
            try store.jobs(meeting: m).first { $0.id == running.id }.map { $0.state == .suspended && $0.suspension == .recordingActive } ?? false
        }, "a running heavy stage is interrupted and shown as suspended, not failed or stuck")
        #expect(try store.jobs(meeting: m).allSatisfy { !($0.key.stage.isHeavy && $0.state == .running) }, "nothing heavy runs while recording")
        exec.delay = .milliseconds(30)
        pressure.value = .none
        s.poke()
        #expect(try await JobFixture.wait { try store.jobs(meeting: m).contains { $0.key.stage == .reconcile && $0.state == .succeeded } })
        #expect(try store.jobs(meeting: m).first { $0.id == running.id }?.state == .succeeded)
    }

    @Test(arguments: [(JobScheduler.Pressure.thermal, SuspensionReason.thermalPressure), (.memory, .memoryPressure)])
    func thermalAndMemoryPressureSuspendHeavyStages(_ p: JobScheduler.Pressure, _ reason: SuspensionReason) async throws {
        let (store, m, root) = try JobFixture.storeWithMeeting()
        defer { try? FileManager.default.removeItem(at: root) }
        let pressure = PressureBox()
        pressure.value = p
        let s = JobScheduler(store: store, executor: FakeExecutor(), configuration: JobFixture.config(), pressure: { pressure.value })
        try s.start()
        defer { s.stop() }
        try s.enqueuePipeline(m)
        #expect(try await JobFixture.wait { try store.jobs(meeting: m).filter { $0.state == .suspended }.count == 2 })
        #expect(try store.jobs(meeting: m).filter { $0.state == .suspended }.allSatisfy { $0.suspension == reason })
        #expect(MeetingStatus(meeting: try store.meeting(m)!, jobs: try store.jobs(meeting: m), events: []).processing == .waiting(reason))
        pressure.value = .none
        s.poke()
        #expect(try await JobFixture.wait { try store.jobs(meeting: m).contains { $0.key.stage == .reconcile && $0.state == .succeeded } })
    }

    @Test func pressurePolicyMapsAppSignals() {
        typealias P = JobScheduler.Pressure
        #expect(P.current(recording: false, thermal: .nominal, memoryPressure: false) == .none)
        #expect(P.current(recording: false, thermal: .fair, memoryPressure: false) == .none)
        #expect(P.current(recording: false, thermal: .serious, memoryPressure: false) == .thermal)
        #expect(P.current(recording: false, thermal: .critical, memoryPressure: true) == .thermal)
        #expect(P.current(recording: false, thermal: .nominal, memoryPressure: true) == .memory)
        #expect(P.current(recording: true, thermal: .critical, memoryPressure: true) == .recording)
    }

    @Test func notesRunOnceThenGoStaleAndRegenerateOnRequest() async throws {
        let (store, m, root) = try JobFixture.storeWithMeeting()
        defer { try? FileManager.default.removeItem(at: root) }
        let exec = FakeExecutor()
        var cfg = JobFixture.config(); cfg.notesConfigHash = "notes-test"
        let s = JobScheduler(store: store, executor: exec, configuration: cfg)
        try s.start()
        defer { s.stop() }
        try s.enqueuePipeline(m)
        #expect(try await JobFixture.wait { try store.currentSummary(m) != nil })
        let first = try #require(try store.currentSummary(m))
        let currentTranscript = try store.meeting(m)?.currentTranscriptRevisionID
        #expect(!first.isStale && first.transcriptRevisionID == currentTranscript)
        try store.saveManualNotes(ManualNotesRevision(meetingID: m, basedOnSummaryRevisionID: first.id, markdown: "my notes", createdAt: Date()))

        // A speaker edit re-reconciles; notes become stale instead of silently regenerating.
        let rev = try #require(try store.meeting(m)?.currentTranscriptRevisionID)
        let spk = try #require(try store.transcriptRevision(rev)?.speakers.first)
        try store.appendEdit(UserEdit(meetingID: m, baseRevisionID: rev, sequence: 1, createdAt: Date(), operation: .renameSpeaker(spk.id, displayName: "Dana")))
        try s.enqueueReconcile(m)
        #expect(try await JobFixture.wait { try store.meeting(m)?.currentTranscriptRevisionID != rev })
        #expect(try await JobFixture.wait { try store.currentSummary(m)?.isStale == true })
        try await Task.sleep(for: .milliseconds(300))
        #expect(try store.jobs(meeting: m).filter { $0.key.stage == .notes }.count == 1, "no automatic regeneration")

        // A failed regeneration leaves the previous summary current and user notes untouched.
        exec.lock.withLock { exec.failing[m] = .notes }
        let failing = try #require(try s.enqueueNotes(m))
        #expect(try await JobFixture.wait { try store.jobs(meeting: m).first { $0.id == failing.id }?.state == .failed })
        #expect(try store.currentSummary(m)?.id == first.id)
        #expect(try store.latestManualNotes(m)?.markdown == "my notes")

        // Retry after the fault: a fresh summary for the current transcript, not stale.
        exec.lock.withLock { exec.failing = [:] }
        for var j in try store.jobs(meeting: m, states: [.failed]) { try j.transition(to: .queued, at: Date()); try store.upsertJob(j) }
        s.poke()
        #expect(try await JobFixture.wait { try store.currentSummary(m).map { $0.id != first.id && !$0.isStale } ?? false })
        #expect(try store.latestManualNotes(m)?.markdown == "my notes")
        #expect(try store.summaryRevisions(m).count == 2)
    }

    @Test func noNotesModelMeansNoNotesJobAndDeletedMeetingsGetNoSummary() async throws {
        let (store, m, root) = try JobFixture.storeWithMeeting()
        defer { try? FileManager.default.removeItem(at: root) }
        let s = JobScheduler(store: store, executor: FakeExecutor(), configuration: JobFixture.config())
        try s.start()
        defer { s.stop() }
        try s.enqueuePipeline(m)
        #expect(try await JobFixture.wait { try store.jobs(meeting: m).contains { $0.key.stage == .reconcile && $0.state == .succeeded } })
        try await Task.sleep(for: .milliseconds(200))
        #expect(!(try store.jobs(meeting: m).contains { $0.key.stage == .notes }))
        #expect(try s.enqueueNotes(m) == nil)
        // A late summary for a deleted meeting is refused by the store.
        let tr = try #require(try store.meeting(m)?.currentTranscriptRevisionID)
        try store.tombstone(m)
        let late = SummaryRevision(meetingID: m, transcriptRevisionID: tr, editSequence: 0, createdAt: Date(),
                                   producer: ProducerInfo(component: "t", configHash: "t"), promptVersion: "t",
                                   content: SummaryContent(), validation: SummaryValidationReport(status: .valid))
        #expect(try store.publishSummary(late) == false)
        #expect(try store.summaryRevisions(m).isEmpty)
    }

    @Test func workerLossIsRetriedWithBackoff() async throws {
        let (store, m, root) = try JobFixture.storeWithMeeting()
        defer { try? FileManager.default.removeItem(at: root) }
        let exec = FakeExecutor()
        exec.workerLossesRemaining = 2
        let s = JobScheduler(store: store, executor: exec, configuration: JobFixture.config())
        try s.start()
        defer { s.stop() }
        try s.enqueuePipeline(m)
        #expect(try await JobFixture.wait { try store.jobs(meeting: m).contains { $0.key.stage == .reconcile && $0.state == .succeeded } })
        let prep = try #require(try store.jobs(meeting: m).first { $0.key.stage == .prepare })
        #expect(prep.attempt == 3, "two simulated worker crashes, then success")
        #expect(prep.state == .succeeded)
    }

    @Test func secondMeetingRightAfterTheFirstWithColdModelAndFailedPriorStage() async throws {
        let (store, m1, root) = try JobFixture.storeWithMeeting()
        defer { try? FileManager.default.removeItem(at: root) }
        let exec = FakeExecutor()
        exec.coldStartDelay = .milliseconds(400)
        exec.failing[m1] = .diarize
        let pressure = PressureBox()
        let s = JobScheduler(store: store, executor: exec, configuration: JobFixture.config(), pressure: { pressure.value })
        try s.start()
        defer { s.stop() }
        // Meeting 1 stops and is queued; meeting 2 starts recording immediately.
        try s.enqueuePipeline(m1)
        pressure.value = .recording
        s.poke()
        // Meeting 2 records, then stops: it is queued behind meeting 1's failure without being blocked by it.
        let m2 = MeetingID()
        try store.upsertMeeting(Meeting(id: m2, title: "second", createdAt: Date(), captureState: .captured))
        try store.insertSegments([AudioSegmentRecord(meetingID: m2, source: .systemOutput, epochID: EpochID(), sequence: 0,
                                                     format: AudioFormat(sampleRate: 16_000, channelCount: 1, sampleFormat: .float32),
                                                     firstFrameInEpoch: 0, frameCount: 32_000, interval: .seconds(0, 2), relativePath: "y.caf",
                                                     sha256: String(repeating: "b", count: 64), state: .committed)])
        try s.enqueuePipeline(m2)
        pressure.value = .none
        s.poke()
        #expect(try await JobFixture.wait { try store.jobs(meeting: m2).contains { $0.key.stage == .reconcile && $0.state == .succeeded } })
        #expect(try await JobFixture.wait { try store.jobs(meeting: m1).contains { $0.key.stage == .diarize && $0.state == .failed } })
        // Meeting 1 keeps its ASR transcript, shows the failure, and can be retried; nothing of meeting 2 is lost.
        let jobs1 = try store.jobs(meeting: m1)
        #expect(jobs1.contains { $0.key.stage == .transcribe && $0.state == .succeeded })
        #expect(!jobs1.contains { $0.key.stage == .reconcile && $0.state == .succeeded }, "reconcile never runs on a failed input")
        guard case .failed(.diarize, _) = MeetingStatus(meeting: try store.meeting(m1)!, jobs: jobs1, events: []).processing else {
            Issue.record("meeting 1 should show the diarization failure"); return
        }
        #expect(try store.meeting(m2)?.currentTranscriptRevisionID != nil)
        exec.lock.withLock { exec.failing = [:] }
        for var j in try store.jobs(meeting: m1, states: [.failed]) { try j.transition(to: .queued, at: Date()); try store.upsertJob(j) }
        s.poke()
        #expect(try await JobFixture.wait { try store.jobs(meeting: m1).contains { $0.key.stage == .reconcile && $0.state == .succeeded } })
    }

    @Test func relaunchRequeuesJobsLeftRunningByADeadProcess() async throws {
        let (store, m, root) = try JobFixture.storeWithMeeting()
        defer { try? FileManager.default.removeItem(at: root) }
        // A previous app instance died mid-prepare.
        let first = JobScheduler(store: store, executor: FakeExecutor(), configuration: JobFixture.config(), owner: "dead-app")
        var j = try first.enqueuePipeline(m)
        try j.transition(to: .running, at: Date())
        j.lease = JobLease(owner: "dead-app", heartbeatAt: Date(), expiresAt: Date().addingTimeInterval(600))
        try store.upsertJob(j)
        let relaunched = JobScheduler(store: store, executor: FakeExecutor(), configuration: JobFixture.config(), owner: "new-app")
        try relaunched.start()
        defer { relaunched.stop() }
        #expect(try await JobFixture.wait { try store.jobs(meeting: m).contains { $0.key.stage == .reconcile && $0.state == .succeeded } })
        #expect(try store.jobs(meeting: m).filter { $0.key.stage == .prepare }.count == 1, "requeued, not duplicated")
    }

    @Test func deletionDuringProcessingNeverPublishesLateResults() async throws {
        let (store, m, root) = try JobFixture.storeWithMeeting()
        defer { try? FileManager.default.removeItem(at: root) }
        let exec = FakeExecutor()
        let (stream, cont) = AsyncStream<Void>.makeStream()
        exec.gate[.transcribe] = stream          // transcribe blocks until released
        exec.gate[.diarize] = stream
        let s = JobScheduler(store: store, executor: exec, configuration: JobFixture.config())
        try s.start()
        defer { s.stop() }
        try s.enqueuePipeline(m)
        #expect(try await JobFixture.wait { try store.jobs(meeting: m).contains { $0.key.stage == .transcribe && $0.state == .running } })
        try s.delete(m)
        cont.yield(); cont.yield(); cont.finish() // the worker finishes after deletion
        try await Task.sleep(for: .milliseconds(400))
        #expect(try store.meeting(m)?.deletedAt != nil)
        #expect(try store.meeting(m)?.currentTranscriptRevisionID == nil, "a late result must not resurrect a deleted meeting")
        #expect(try store.transcriptRevisions(m).isEmpty)
        #expect(try store.jobs(meeting: m).isEmpty, "purged job rows are not re-created by late updates")
        #expect(try store.diarization(RevisionID("none")) == nil)
        #expect(!FileManager.default.fileExists(atPath: store.workDirectory(m).path), "a late worker cannot leave files behind")
    }

    @Test func speakerEditsStillWorkAfterAudioOnlyDeletion() async throws {
        let (store, m, root) = try JobFixture.storeWithMeeting()
        defer { try? FileManager.default.removeItem(at: root) }
        let s = JobScheduler(store: store, executor: FakeExecutor(), configuration: JobFixture.config())
        try s.start()
        defer { s.stop() }
        try s.enqueuePipeline(m)
        #expect(try await JobFixture.wait { try store.jobs(meeting: m).contains { $0.key.stage == .reconcile && $0.state == .succeeded } })
        try s.deleteAudio(m)
        let rev = try #require(try store.meeting(m)?.currentTranscriptRevisionID)
        let spk = try #require(try store.transcriptRevision(rev)?.speakers.first)
        try store.appendEdit(UserEdit(meetingID: m, baseRevisionID: rev, sequence: 1, createdAt: Date(), operation: .renameSpeaker(spk.id, displayName: "Dana")))
        try s.enqueueReconcile(m)
        #expect(try await JobFixture.wait {
            try store.meeting(m)?.currentTranscriptRevisionID.flatMap { try store.transcriptRevision($0) }?.speakers.contains { $0.displayName == "Dana" } ?? false
        }, "the rename is applied after the audio is gone")
        #expect(try store.meeting(m)?.audio == .deletedByUser)
    }

    @Test func editsDuringReconcileAreNotOverwritten() async throws {
        let (store, m, root) = try JobFixture.storeWithMeeting()
        defer { try? FileManager.default.removeItem(at: root) }
        let exec = FakeExecutor()
        let s = JobScheduler(store: store, executor: exec, configuration: JobFixture.config())
        try s.start()
        defer { s.stop() }
        try s.enqueuePipeline(m)
        #expect(try await JobFixture.wait { try store.jobs(meeting: m).contains { $0.key.stage == .reconcile && $0.state == .succeeded } })
        let r1 = try #require(try store.meeting(m)?.currentTranscriptRevisionID.flatMap { try store.transcriptRevision($0) })
        // User renames a speaker; reconcile reruns; the rename survives.
        try store.appendEdit(UserEdit(meetingID: m, baseRevisionID: r1.id, sequence: 1, createdAt: Date(),
                                      operation: .renameSpeaker(r1.speakers[0].id, displayName: "Dana")))
        try s.enqueueReconcile(m)
        #expect(try await JobFixture.wait {
            try store.meeting(m)?.currentTranscriptRevisionID.flatMap { try store.transcriptRevision($0) }?.speakers.contains { $0.displayName == "Dana" } ?? false
        })
    }

    @Test func resultComputedFromStaleEditsIsDiscardedAndRecomputed() async throws {
        let (store, m, root) = try JobFixture.storeWithMeeting()
        defer { try? FileManager.default.removeItem(at: root) }
        let exec = FakeExecutor()
        let s = JobScheduler(store: store, executor: exec, configuration: JobFixture.config())
        try s.start()
        defer { s.stop() }
        try s.enqueuePipeline(m)
        #expect(try await JobFixture.wait { try store.jobs(meeting: m).contains { $0.key.stage == .reconcile && $0.state == .succeeded } })
        let r1 = try #require(try store.meeting(m)?.currentTranscriptRevisionID.flatMap { try store.transcriptRevision($0) })
        // Edit 1 → reconcile #2 starts and is held open; meanwhile the user makes edit 2.
        let (stream, cont) = AsyncStream<Void>.makeStream()
        exec.lock.withLock { exec.gate[.reconcile] = stream }
        try store.appendEdit(UserEdit(meetingID: m, baseRevisionID: r1.id, sequence: 1, createdAt: Date(),
                                      operation: .renameSpeaker(r1.speakers[0].id, displayName: "Dana")))
        try s.enqueueReconcile(m)
        #expect(try await JobFixture.wait { try store.jobs(meeting: m).contains { $0.key.stage == .reconcile && $0.state == .running } })
        try store.appendEdit(UserEdit(meetingID: m, baseRevisionID: r1.id, sequence: 2, createdAt: Date(),
                                      operation: .renameSpeaker(r1.speakers[1].id, displayName: "Lee")))
        exec.lock.withLock { exec.gate[.reconcile] = nil }
        cont.yield(); cont.finish()
        // The result built from edit 1 only must be discarded; a fresh reconcile publishes both renames.
        #expect(try await JobFixture.wait {
            let sp = try store.meeting(m)?.currentTranscriptRevisionID.flatMap { try store.transcriptRevision($0) }?.speakers ?? []
            return sp.contains { $0.displayName == "Dana" } && sp.contains { $0.displayName == "Lee" }
        })
        #expect(try store.jobs(meeting: m).contains { $0.key.stage == .reconcile && $0.errorCode == "stale.edits" })
    }
}
