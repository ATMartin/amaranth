import Foundation
import Testing
import Domain
import DomainFixtures

@Suite("Domain invariants")
struct InvariantTests {
    @Test func frameToTimeIsExactOverLongSessions() {
        // 4 hours at 44.1 kHz: integer math must not drift.
        let frames: Int64 = 44_100 * 3600 * 4
        #expect(SessionTime.zero.advanced(byFrames: frames, sampleRate: 44_100).nanoseconds == 4 * 3600 * 1_000_000_000)
        #expect(SessionTime.zero.advanced(byFrames: 1, sampleRate: 48_000).nanoseconds == 20_833)
    }

    @Test func intervalOverlapIsHalfOpen() {
        #expect(!SessionInterval.seconds(0, 1).overlaps(.seconds(1, 2)))
        #expect(SessionInterval.seconds(0, 1.5).intersection(.seconds(1, 2)) == .seconds(1, 1.5))
    }

    @Test("Fixture transcripts satisfy structural invariants", arguments: Fixtures.all.compactMap(\.transcript))
    func transcriptsValidate(_ t: TranscriptRevision) throws {
        try t.validate()
    }

    @Test func summaryEvidenceResolves() throws {
        let f = Fixtures.twoSourceConversation
        try f.summary!.validateReferences(transcript: f.transcript!, scratchpad: f.scratchpad)
    }

    @Test func summaryEvidenceAgainstWrongRevisionFails() throws {
        let f = Fixtures.twoSourceConversation
        var other = f.transcript!
        other.id = RevisionID("other")
        #expect(throws: DomainError.self) { try f.summary!.validateReferences(transcript: other, scratchpad: nil) }
    }

    @Test func personalNoteEvidenceRequiresOptIn() throws {
        let f = Fixtures.twoSourceConversation
        var s = f.summary!
        s.content.overview[0].evidence.append(.personalNote(.init(revisionID: f.scratchpad!.id, start: 0, end: 3)))
        #expect(throws: DomainError.self) { try s.validateReferences(transcript: f.transcript!, scratchpad: f.scratchpad) }
        s.influencedByPersonalNotes = true
        try s.validateReferences(transcript: f.transcript!, scratchpad: f.scratchpad)
    }

    @Test func snapshotDropsScratchpadUnlessIncluded() {
        let f = Fixtures.twoSourceConversation
        #expect(SummaryInputSnapshot(transcript: f.transcript!, edits: [], scratchpad: f.scratchpad).scratchpad == nil)
        var pad = f.scratchpad!
        pad.includeInSummary = true
        #expect(SummaryInputSnapshot(transcript: f.transcript!, edits: [], scratchpad: pad).scratchpad != nil)
    }

    @Test func floatingModelRevisionsRejected() {
        let m = ModelManifest(id: ModelManifestID("x"), version: "1", role: .asr, family: "f", sourceRepository: "r",
                              sourceRevision: "main", conversionProvenance: "", files: [],
                              license: ModelLicense(identifier: "MIT", attribution: ""), minimumOS: "26.5.2")
        #expect(throws: DomainError.self) { try m.validatePinning() }
    }

    @Test func captureStateMachine() {
        #expect(CaptureState.idle.canTransition(to: .preparing))
        #expect(CaptureState.recording.canTransition(to: .paused))
        #expect(CaptureState.paused.canTransition(to: .recording))
        #expect(!CaptureState.captured.canTransition(to: .recording), "a sealed session is never silently reopened")
        #expect(!CaptureState.idle.canTransition(to: .recording), "recording only after preparing succeeds")
    }

    @Test func processingStateMachineAndAttempts() throws {
        var j = ProcessingJob(key: JobKey(meetingID: MeetingID("m"), stage: .notes, inputHash: "i", configHash: "c"),
                              createdAt: Fixtures.referenceDate, updatedAt: Fixtures.referenceDate)
        try j.transition(to: .running, at: .now)
        try j.transition(to: .failed, at: .now)
        try j.transition(to: .queued, at: .now)
        try j.transition(to: .running, at: .now)
        #expect(j.attempt == 2)
        #expect(throws: DomainError.self) { try j.transition(to: .suspended, at: .now); try j.transition(to: .succeeded, at: .now) }
    }

    @Test func stageDAG() {
        #expect(ProcessingStage.reconcile.prerequisites == [.transcribe, .diarize])
        #expect(ProcessingStage.notes.isHeavy && ProcessingStage.transcribe.isHeavy && !ProcessingStage.reconcile.isHeavy)
    }
}

@Suite("Fixture scenarios")
struct FixtureScenarioTests {
    @Test func capturedAudioDistinctFromFailedProcessing() {
        let s = Fixtures.missingSource.status
        #expect(s.audioIsSaved)
        #expect(s.audio == .savedWithGaps(missingSeconds: 15))
        #expect(s.processing == .failed(.notes, errorCode: "notes.schemaInvalid"))
        #expect(s.stages[.transcribe] == .succeeded, "earlier stage outputs remain usable")
    }

    @Test func missingSourceIsExplicitNotSilence() throws {
        let f = Fixtures.missingSource
        let gap = try #require(f.events.first { $0.isMissingAudio })
        #expect(gap.source == .systemOutput && gap.interval == .seconds(20, 35))
        let cov = try #require(f.transcript?.coverage.first { $0.status == .missingAudio })
        #expect(cov.interval == gap.interval)
        // No system segments inside the gap.
        #expect(!f.audioSegments.contains { $0.source == .systemOutput && $0.interval.overlaps(gap.interval) })
        // Microphone remained healthy throughout.
        let micSecs = f.audioSegments.filter { $0.source == .microphone }.reduce(0.0) { $0 + $1.interval.duration.seconds }
        #expect(micSecs == 60)
    }

    @Test func pauseCreatesEpochsWithoutCollapsingTimeline() throws {
        let f = Fixtures.pausedMeeting
        #expect(f.epochs.filter { $0.source == .microphone }.map(\.index) == [0, 1])
        let resumed = try #require(f.epochs.first { $0.source == .microphone && $0.index == 1 })
        #expect(resumed.reason == .resume && resumed.sessionStart == .seconds(45))
        let firstAfter = try #require(f.audioSegments.first { $0.source == .microphone && $0.epochID == resumed.id })
        #expect(firstAfter.interval.start == .seconds(45), "later timestamps are not shifted back over the pause")
        #expect(firstAfter.firstFrameInEpoch == 0)
        #expect(f.status.processing == .waiting(.recordingActive))
    }

    @Test func staleSummaryAfterEdits() {
        let f = Fixtures.staleSummary
        #expect(f.summary!.isStale)
        #expect(f.edits.map(\.sequence) == [1, 2])
        #expect(f.summary!.editSequence < f.edits.last!.sequence)
    }

    @Test func fixtureIDsAreUniqueAcrossMeetings() {
        let ids = Fixtures.all.map(\.meeting.id)
        #expect(Set(ids).count == ids.count)
        let segIDs = Fixtures.all.flatMap(\.audioSegments).map(\.id)
        #expect(Set(segIDs).count == segIDs.count)
    }
}

@Suite("Fake worker")
struct FakeWorkerTests {
    @Test func runsAndResumesFromCheckpoint() async throws {
        let w = FakeInferenceWorker()
        let dir = FileManager.default.temporaryDirectory.appending(path: "amaranth-fake-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let job = JobDescriptor(jobID: JobID("j1"), key: JobKey(meetingID: MeetingID("m"), stage: .transcribe, inputHash: "i", configHash: "c"),
                                workDirectory: dir, checkpoint: JobCheckpoint(completedUnits: 2, totalUnits: 4))
        let seen = Mutex2<[Int]>([])
        let r = try await w.run(job) { p in seen.withLock { $0.append(p.checkpoint!.completedUnits) } }
        guard case .completed(_, let url, let hash) = r else { Issue.record("expected completion"); return }
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(hash.count == 64)
        #expect(seen.withLock { $0 } == [3, 4], "resumes after the checkpoint instead of redoing units")
    }

    @Test func injectedCrashSurfacesAsError() async throws {
        let w = FakeInferenceWorker()
        await w.inject(.crash)
        let job = JobDescriptor(jobID: JobID("j"), key: JobKey(meetingID: MeetingID("m"), stage: .notes, inputHash: "", configHash: ""),
                                workDirectory: URL(filePath: "/tmp"))
        await #expect(throws: FakeInferenceWorker.Failure.crashed) { _ = try await w.handle(.run(job)) }
    }
}

import Synchronization
final class Mutex2<T: Sendable>: Sendable {
    private let m: Mutex<T>
    init(_ v: T) { m = Mutex(v) }
    func withLock<R: Sendable>(_ body: (inout sending T) -> sending R) -> R { m.withLock(body) }
}

