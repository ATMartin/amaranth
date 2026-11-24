import Foundation
import Testing
@testable import ProcessingCore
import Domain
@testable import Storage

/// T117: "Keep audio after processing" (recorded per meeting at Stop) and "Delete all stored audio…".
@Suite("Audio after processing", .serialized)
struct AudioAfterProcessingTests {
    /// A meeting with an original audio file on disk (the fixture's segment row has none).
    static func meeting(deletesAudio: Bool) throws -> (MeetingStore, MeetingID, URL) {
        let (store, m, root) = try JobFixture.storeWithMeeting()
        try writeFile(store.meetingDirectory(m).appending(path: "x.caf"), bytes: 64_000)
        if deletesAudio { try store.setDeletesAudioAfterProcessing(true, for: m) }
        return (store, m, root)
    }

    static func writeFile(_ url: URL, bytes: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
    }

    static func prepareFolders(_ store: MeetingStore, _ m: MeetingID) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: store.workDirectory(m), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("prepare-") }
    }

    static func jobsOver(_ store: MeetingStore, _ m: MeetingID, stages: Int) throws -> Bool {
        let jobs = try store.jobs(meeting: m)
        return jobs.count >= stages && jobs.allSatisfy(\.state.isTerminal)
    }

    @Test func settingOnKeepsAudio() async throws {
        let (store, m, root) = try Self.meeting(deletesAudio: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let s = JobScheduler(store: store, executor: FakeExecutor(), configuration: JobFixture.config(notes: true))
        try s.start(); defer { s.stop() }
        try s.enqueuePipeline(m)
        #expect(try await JobFixture.wait { try store.currentSummary(m) != nil && Self.jobsOver(store, m, stages: 5) })
        try await Task.sleep(for: .milliseconds(200))
        #expect(try store.meeting(m)?.audio == .present)
        #expect(FileManager.default.fileExists(atPath: store.meetingDirectory(m).appending(path: "x.caf").path))
        #expect(!Self.prepareFolders(store, m).isEmpty, "analysis copies stay")
    }

    @Test func settingOffDeletesAudioAfterProcessingAndKeepsText() async throws {
        let (store, m, root) = try Self.meeting(deletesAudio: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let exec = FakeExecutor()
        let (notesGate, release) = AsyncStream<Void>.makeStream()
        exec.gate[.notes] = notesGate
        let s = JobScheduler(store: store, executor: exec, configuration: JobFixture.config(notes: true))
        try s.start(); defer { s.stop() }
        try s.enqueuePipeline(m)
        #expect(try await JobFixture.wait { try store.jobs(meeting: m).contains { $0.key.stage == .notes && $0.state == .running } })
        #expect(try store.meeting(m)?.audio == .present, "audio stays while notes are still being written")
        // A user edit made meanwhile must survive the deletion.
        let rev = try #require(try store.meeting(m)?.currentTranscriptRevisionID)
        let speaker = try #require(try store.transcriptRevision(rev)?.speakers.first)
        try store.appendEdit(UserEdit(meetingID: m, baseRevisionID: rev, sequence: 1, createdAt: Date(), operation: .renameSpeaker(speaker.id, displayName: "Dana")))
        release.yield(); release.finish()
        #expect(try await JobFixture.wait { try store.meeting(m)?.audio == .deletedByUser })
        #expect(!FileManager.default.fileExists(atPath: store.meetingDirectory(m).path), "original audio removed")
        #expect(Self.prepareFolders(store, m).isEmpty, "analysis copies removed")
        #expect(try store.segments(m).isEmpty)
        #expect(try store.meeting(m)?.currentTranscriptRevisionID == rev, "transcript kept")
        #expect(try store.transcriptRevision(rev)?.speakers.isEmpty == false, "speakers kept")
        #expect(try store.currentSummary(m) != nil, "notes kept")
        #expect(try store.edits(m).count == 1, "edits kept")
        #expect(store.storedAudioBytes(m) == 0)
    }

    @Test func notesFailureStillDeletesAudio() async throws {
        let (store, m, root) = try Self.meeting(deletesAudio: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let exec = FakeExecutor()
        exec.failing[m] = .notes
        let s = JobScheduler(store: store, executor: exec, configuration: JobFixture.config(notes: true))
        try s.start(); defer { s.stop() }
        try s.enqueuePipeline(m)
        #expect(try await JobFixture.wait { try store.meeting(m)?.audio == .deletedByUser }, "notes need no audio to be retried")
        #expect(try store.jobs(meeting: m).contains { $0.key.stage == .notes && $0.state == .failed })
        #expect(try store.meeting(m)?.currentTranscriptRevisionID != nil)
    }

    @Test func noNotesModelDeletesOnceSpeakersAreReconciled() async throws {
        let (store, m, root) = try Self.meeting(deletesAudio: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let s = JobScheduler(store: store, executor: FakeExecutor(), configuration: JobFixture.config(notes: false))
        try s.start(); defer { s.stop() }
        try s.enqueuePipeline(m)
        #expect(try await JobFixture.wait { try store.meeting(m)?.audio == .deletedByUser })
    }

    @Test(arguments: [ProcessingStage.transcribe, .diarize])
    func transcriptOrSpeakerFailureKeepsAudio(_ stage: ProcessingStage) async throws {
        let (store, m, root) = try Self.meeting(deletesAudio: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let exec = FakeExecutor()
        exec.failing[m] = stage
        let s = JobScheduler(store: store, executor: exec, configuration: JobFixture.config(notes: true))
        try s.start(); defer { s.stop() }
        try s.enqueuePipeline(m)
        #expect(try await JobFixture.wait { try store.jobs(meeting: m).contains { $0.key.stage == stage && $0.state == .failed } && Self.jobsOver(store, m, stages: 3) })
        try await Task.sleep(for: .milliseconds(300))
        #expect(try store.meeting(m)?.audio == .present, "Retry needs the audio")
        #expect(FileManager.default.fileExists(atPath: store.meetingDirectory(m).appending(path: "x.caf").path))
        // Retry succeeds → now the audio goes.
        exec.failing[m] = nil
        for var j in try store.jobs(meeting: m, states: [.failed]) { try j.transition(to: .queued, at: Date()); j.notBefore = nil; try store.upsertJob(j) }
        s.poke()
        #expect(try await JobFixture.wait { try store.meeting(m)?.audio == .deletedByUser })
    }

    @Test func choiceRecordedAtStopWinsOverLaterChanges() async throws {
        // A stopped with the setting off; B stopped after it was turned back on. Each follows its own recorded choice.
        let (store, a, root) = try Self.meeting(deletesAudio: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let b = MeetingID()
        try store.upsertMeeting(Meeting(id: b, title: "b", createdAt: Date(), captureState: .captured))
        try store.insertSegments([AudioSegmentRecord(meetingID: b, source: .systemOutput, epochID: EpochID(), sequence: 0,
                                                     format: AudioFormat(sampleRate: 16_000, channelCount: 1, sampleFormat: .float32), firstFrameInEpoch: 0,
                                                     frameCount: 32_000, interval: .seconds(0, 2), relativePath: "x.caf",
                                                     sha256: String(repeating: "b", count: 64), state: .committed)])
        try Self.writeFile(store.meetingDirectory(b).appending(path: "x.caf"), bytes: 64_000)
        // Writers holding an older copy of A (recorder, rename) don't drop the recorded choice.
        var stale = try #require(try store.meeting(a)); stale.deletesAudioAfterProcessing = false; stale.title = "renamed"
        try store.upsertMeeting(stale)
        #expect(try store.meeting(a)?.deletesAudioAfterProcessing == true)
        let s = JobScheduler(store: store, executor: FakeExecutor(), configuration: JobFixture.config())
        try s.start(); defer { s.stop() }
        try s.enqueuePipeline(a); try s.enqueuePipeline(b)
        #expect(try await JobFixture.wait { try store.meeting(a)?.audio == .deletedByUser })
        #expect(try await JobFixture.wait { try Self.jobsOver(store, b, stages: 4) })
        try await Task.sleep(for: .milliseconds(200))
        #expect(try store.meeting(b)?.audio == .present)
    }

    @Test func relaunchDeletesAudioOfAMeetingThatFinishedBeforeQuit() async throws {
        let (store, m, root) = try Self.meeting(deletesAudio: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = JobScheduler(store: store, executor: FakeExecutor(), configuration: JobFixture.config())
        try first.start()
        try first.enqueuePipeline(m)
        #expect(try await JobFixture.wait { try Self.jobsOver(store, m, stages: 4) })
        first.stop()
        // As if the app quit between the last job and the deletion.
        try store.setDeletesAudioAfterProcessing(true, for: m)
        #expect(try store.meeting(m)?.audio == .present)
        let second = JobScheduler(store: store, executor: FakeExecutor(), configuration: JobFixture.config())
        try second.start(); defer { second.stop() }
        #expect(try store.meeting(m)?.audio == .deletedByUser)
    }

    @Test func neverDeletesWhileRecordingOrWithWorkPending() async throws {
        let (store, m, root) = try Self.meeting(deletesAudio: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let s = JobScheduler(store: store, executor: FakeExecutor(), configuration: JobFixture.config())
        try s.start()
        try s.enqueuePipeline(m)
        #expect(try await JobFixture.wait { try Self.jobsOver(store, m, stages: 4) })
        s.stop()
        try store.setDeletesAudioAfterProcessing(true, for: m)
        var recording = try #require(try store.meeting(m)); recording.captureState = .recording
        try store.upsertMeeting(recording)
        #expect(try s.deleteAudioIfProcessed(m) == false, "a recording meeting keeps its audio")
        recording.captureState = .captured
        try store.upsertMeeting(recording)
        try store.enqueue(ProcessingJob(key: JobKey(meetingID: m, stage: .reconcile, inputHash: "again", configHash: "r"), createdAt: Date(), updatedAt: Date()))
        #expect(try s.deleteAudioIfProcessed(m) == false, "pending work keeps the audio")
        #expect(try store.meeting(m)?.audio == .present)
    }

    @Test func deleteAllSkipsRecordingAndPendingMeetingsAndKeepsText() async throws {
        let (store, done, root) = try Self.meeting(deletesAudio: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let s = JobScheduler(store: store, executor: FakeExecutor(), configuration: JobFixture.config(notes: true))
        try s.start()
        try s.enqueuePipeline(done)
        #expect(try await JobFixture.wait { try store.currentSummary(done) != nil && Self.jobsOver(store, done, stages: 5) })
        s.stop()
        func add(_ title: String, _ state: CaptureState) throws -> MeetingID {
            let id = MeetingID()
            try store.upsertMeeting(Meeting(id: id, title: title, createdAt: Date(), captureState: state))
            try Self.writeFile(store.meetingDirectory(id).appending(path: "a.caf"), bytes: 32_000)
            return id
        }
        let recording = try add("recording", .recording)
        let recorderNamed = try add("named by the recorder", .captured)
        let pending = try add("pending", .captured)
        try store.enqueue(ProcessingJob(key: JobKey(meetingID: pending, stage: .transcribe, inputHash: "h", configHash: "asr"), createdAt: Date(), updatedAt: Date()))
        let notesOnly = try add("notes pending", .captured)
        try store.enqueue(ProcessingJob(key: JobKey(meetingID: notesOnly, stage: .notes, inputHash: "h", configHash: "notes"), createdAt: Date(), updatedAt: Date()))
        let noAudio = try add("audio already deleted", .captured)
        try s.deleteAudio(noAudio)

        let before = try store.storedAudioUsage()
        #expect(Set(before.meetings) == [done, recording, recorderNamed, pending, notesOnly])
        let transcript = try store.meeting(done)?.currentTranscriptRevisionID
        let r = try s.deleteAllStoredAudio(recording: [recorderNamed])
        #expect(Set(r.deleted) == [done, notesOnly], "pending notes don't block: they need no audio")
        #expect(Set(r.skipped) == [recording, recorderNamed, pending])
        for id in [recording, recorderNamed, pending] { #expect(try store.meeting(id)?.audio == .present) }
        #expect(try store.meeting(done)?.audio == .deletedByUser)
        #expect(try store.meeting(done)?.currentTranscriptRevisionID == transcript)
        #expect(try store.currentSummary(done) != nil)
        let after = try store.storedAudioUsage()
        #expect(Set(after.meetings) == [recording, recorderNamed, pending])
        #expect(after.bytes == [recording, recorderNamed, pending].map(store.storedAudioBytes).reduce(0, +))
    }

    @Test func storedAudioTotalIsOriginalsPlusAnalysisCopies() throws {
        let (store, m, root) = try Self.meeting(deletesAudio: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let work = store.workDirectory(m)
        try Self.writeFile(work.appending(path: "prepare-abc/analysis.wav"), bytes: 48_000)
        try Self.writeFile(work.appending(path: "prepare-abc/coverage.json"), bytes: 100)
        try Self.writeFile(work.appending(path: "incremental/window.wav"), bytes: 16_000)
        try Self.writeFile(work.appending(path: "transcribe-abc/output.json"), bytes: 8_000)
        let usage = store.diskUsage(m)
        let text = MeetingStore.bytes(work.appending(path: "transcribe-abc"))
        #expect(text > 0)
        #expect(store.storedAudioBytes(m) == usage.totalBytes - text, "everything Delete audio removes, nothing it keeps")
        #expect(try store.storedAudioUsage().bytes == store.storedAudioBytes(m))
        #expect(try store.storedAudioUsage().meetings == [m])
    }
}
