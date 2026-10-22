import Foundation
import Testing
@testable import Presentation
import Storage
import Domain
import DomainFixtures
import ProcessingCore

/// Persists a fixture meeting through the real store, so the UI's integration path can be compared with fixtures.
func persist(_ f: FixtureMeeting, in store: MeetingStore) throws {
    try store.upsertMeeting(f.meeting)
    try store.insertEpochs(f.epochs)
    try store.insertSegments(f.audioSegments)
    try store.insertEvents(f.events)
    if let t = f.transcript { try store.publishTranscript(t) }
    for e in f.edits { try store.appendEdit(e) }
    if let s = f.summary { try store.publishSummary(s) }
    for j in f.jobs { try store.upsertJob(j) }
}

func tempStore() throws -> (MeetingStore, URL) {
    let root = FileManager.default.temporaryDirectory.appending(path: "amr-ui-\(UUID())")
    return (try MeetingStore(root: root), root)
}

@Suite("Presentation: fixtures and integration agree")
struct PresentationIntegrationTests {
    @Test(arguments: Fixtures.all.map(\.name))
    func fixtureAndStoreRenderTheSame(_ name: String) throws {
        let f = try #require(Fixtures.all.first { $0.name == name })
        let (store, root) = try tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try persist(f, in: store)
        let d = try #require(try MeetingDetail.load(store, f.meeting.id))
        // Same rows from the fixture directly and through the store.
        let direct = f.transcript.map { TranscriptRows.build($0, edits: f.edits) } ?? []
        #expect(d.rows == direct)
        // Unknown speakers are labelled, never guessed.
        for r in d.rows where !r.isGap && r.assignment == .unknown { #expect(r.speakerLabel == "Unknown speaker") }
        // Gaps from coverage appear as rows (missing audio is never silently omitted).
        let gapCoverage = (f.transcript?.coverage ?? []).filter { TranscriptRows.gapReason($0.status) != nil && $0.interval.duration.seconds >= 1 }
        #expect(d.rows.filter(\.isGap).count == gapCoverage.count)
        // Status is the same contract-derived headline the fixture UI shows.
        #expect(d.status.audio == f.status.audio)
        // Playback availability follows the audio state.
        #expect((d.playbackUnavailableReason == nil) == (f.meeting.audio == .present && !f.audioSegments.isEmpty))
        // Stale notes: what the fixture claims, the store computes.
        if let s = f.summary { #expect(d.summary?.isStale == s.isStale, "stale flag for \(name)") }
    }

    @Test func staleNotesShowAsStaleAndAudioDeletionDisablesPlayback() throws {
        let f = Fixtures.staleSummary
        let (store, root) = try tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try persist(f, in: store)
        let d = try #require(try MeetingDetail.load(store, f.meeting.id))
        guard case .ready(let stale, nil) = d.notesState(notesModelInstalled: true) else { Issue.record("expected ready"); return }
        #expect(stale)
        var m = f.meeting; m.audio = .deletedByUser
        try store.upsertMeeting(m)
        let after = try #require(try MeetingDetail.load(store, f.meeting.id))
        #expect(after.playbackUnavailableReason?.contains("deleted") == true)
    }

    @Test func destructiveActionsSayWhatIsRemovedWhatStaysAndThatItCannotBeUndone() {
        let usage = MeetingStore.DiskUsage(originalAudioBytes: 50_000_000, derivedBytes: 10_000_000)
        let audio = DestructiveAction.deleteAudioOnly.explanation(usage)
        #expect(audio.contains("transcript, notes and your edits stay") && audio.contains("cannot be undone") && audio.contains("60 MB"))
        let all = DestructiveAction.deleteMeeting.explanation(usage)
        #expect(all.contains("transcript, notes") && all.contains("exported earlier are not affected") && all.contains("cannot be undone"))
        #expect(DestructiveAction.deleteMeeting.confirmationTitle("Standup").contains("completely"))
    }
}

@Suite("Presentation logic")
struct PresentationLogicTests {
    @Test func notesStateCoversEveryCase() throws {
        let f = Fixtures.twoSourceConversation
        let (store, root) = try tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        var noSummary = f; noSummary.summary = nil; noSummary.jobs = []
        try persist(noSummary, in: store)
        var d = try #require(try MeetingDetail.load(store, f.meeting.id))
        #expect(d.notesState(notesModelInstalled: false) == .unavailable("Install the model pack to generate notes. Recording and transcripts don't need it."))
        #expect(d.notesState(notesModelInstalled: true) == .none)
        // Words published, speakers still pending: wait rather than offer notes without speakers.
        let attributed = d.transcript
        d.transcript?.stage = .asr
        d.jobs = [ProcessingJob(key: JobKey(meetingID: f.meeting.id, stage: .reconcile, inputHash: "h", configHash: "c"), createdAt: Date(), updatedAt: Date())]
        #expect(d.notesState(notesModelInstalled: true) == .waiting("Notes start when speakers are identified"))
        var diarize = ProcessingJob(key: JobKey(meetingID: f.meeting.id, stage: .diarize, inputHash: "h", configHash: "c"), createdAt: Date(), updatedAt: Date())
        d.jobs = [diarize]
        #expect(d.notesState(notesModelInstalled: true) == .waiting("Notes start when speakers are identified"))
        try diarize.transition(to: .suspended, at: Date()); diarize.suspension = .recordingActive; d.jobs = [diarize]
        #expect(d.notesState(notesModelInstalled: true) == .waiting("Notes start when speakers are identified"))
        try diarize.transition(to: .queued, at: Date()); try diarize.transition(to: .running, at: Date())
        try diarize.transition(to: .failed, at: Date()); d.jobs = [diarize]
        #expect(d.notesState(notesModelInstalled: true) == .none) // diarization failed: generating from words is allowed
        d.jobs = []
        #expect(d.notesState(notesModelInstalled: true) == .none)
        d.transcript = attributed
        var job = ProcessingJob(key: JobKey(meetingID: f.meeting.id, stage: .notes, inputHash: "h", configHash: "c"), createdAt: Date(), updatedAt: Date())
        d.jobs = [job]
        #expect(d.notesState(notesModelInstalled: true) == .waiting("Queued"))
        try job.transition(to: .suspended, at: Date()); job.suspension = .recordingActive; d.jobs = [job]
        #expect(d.notesState(notesModelInstalled: true) == .waiting("Waiting — paused while recording"))
        try job.transition(to: .queued, at: Date()); try job.transition(to: .running, at: Date()); job.progress = 0.4; d.jobs = [job]
        #expect(d.notesState(notesModelInstalled: true) == .generating(0.4))
        try job.transition(to: .failed, at: Date()); job.errorCode = "model.missing"; d.jobs = [job]
        #expect(d.notesState(notesModelInstalled: true) == .failed("model.missing"))
        // With prior notes, a later failure keeps them and says so.
        d.summary = f.summary
        d.summary?.createdAt = Date().addingTimeInterval(-60)
        #expect(d.notesState(notesModelInstalled: true) == .ready(stale: f.summary!.isStale, regenerationError: "model.missing"))
    }

    @Test func editComposerBuildsReplayableEdits() throws {
        let f = Fixtures.twoSourceConversation
        let t = try #require(f.transcript)
        let rows = TranscriptRows.build(t, edits: [])
        let c = EditComposer(meetingID: f.meeting.id, revision: t, existing: f.edits)
        let rename = c.rename(t.speakers[0].id, to: "  Dana  ")
        #expect(rename.operation == .renameSpeaker(t.speakers[0].id, displayName: "Dana"))
        #expect(rename.sequence == (f.edits.map(\.sequence).max() ?? 0) + 1 && rename.baseRevisionID == t.id)
        #expect(c.rename(t.speakers[0].id, to: "   ").operation == .renameSpeaker(t.speakers[0].id, displayName: nil))
        let row = try #require(rows.first { !$0.isGap })
        guard case .reassign(let r, .new(_, let label)) = try c.reassign(row, to: c.newSpeakerTarget()).operation else { Issue.record("reassign"); return }
        #expect(r == row.range && !t.speakers.map(\.label).contains(label))
        #expect(throws: EditComposer.Error.sameSpeaker) { try c.merge([t.speakers[0].id], into: t.speakers[0].id) }
        let fix = try c.correct(row, text: " corrected words ")
        let shown = TranscriptRows.build(t, edits: [fix])
        let fixedRow = try #require(shown.first { $0.range?.first == row.range?.first })
        #expect(fixedRow.text.hasPrefix("corrected words") && fixedRow.flags.contains(.corrected))
        #expect(t.segments.flatMap(\.words).contains { $0.id == row.range!.first && $0.text != "corrected words" }, "machine revision untouched")
    }

    @Test func evidenceJumpsToTheRowContainingTheWord() throws {
        let f = Fixtures.twoSourceConversation
        let t = try #require(f.transcript)
        let rows = TranscriptRows.build(t, edits: [])
        let seg = t.segments[1]
        let e = TranscriptEvidence(revisionID: t.id, segmentID: seg.id, firstWord: seg.words[min(2, seg.words.count - 1)].id, lastWord: seg.words.last!.id)
        let row = try #require(TranscriptRows.row(for: e, in: rows, revision: t))
        #expect(row.segmentID == seg.id)
    }

    @Test func twoHourTranscriptBuildsAndLoadsQuickly() throws {
        // 1,800 segments × 30 words ≈ a dense two-hour meeting.
        let speakers = (1...4).map { Speaker(id: SpeakerID("s\($0)"), label: "Speaker \($0)") }
        var segs: [TranscriptSegment] = []
        for i in 0..<1800 {
            let t0 = Double(i) * 4
            let sp = speakers[i % 4].id
            let source: SourceKind = i % 3 == 0 ? .microphone : .systemOutput
            var words: [Word] = []
            for j in 0..<30 {
                let a = t0 + Double(j) * 0.12
                let who: SpeakerAssignment = j == 29 ? .unknown : .speaker(sp)
                words.append(Word(id: WordID("w\(i)-\(j)"), text: "word\(j)", interval: .seconds(a, a + 0.1), source: source, speaker: who))
            }
            segs.append(TranscriptSegment(id: TranscriptSegmentID("seg\(i)"), source: words[0].source, interval: .seconds(t0, t0 + 3.6), words: words, speaker: .speaker(sp)))
        }
        let m = MeetingID()
        let t = TranscriptRevision(meetingID: m, kind: .final, stage: .attributed, createdAt: Date(), producer: ProducerInfo(component: "t", configHash: "t"),
                                   segments: segs, coverage: [CoverageRegion(source: .systemOutput, interval: .seconds(0, 7200), status: .transcribed)], speakers: speakers)
        let edits = (0..<200).map { UserEdit(meetingID: m, baseRevisionID: t.id, sequence: $0 + 1, createdAt: Date(),
                                              operation: .correctText(WordRange(revisionID: t.id, first: WordID("w\($0 * 9)-0"), last: WordID("w\($0 * 9)-2")), replacement: "fixed")) }
        let clock = ContinuousClock()
        var rows: [TranscriptRow] = []
        let build = clock.measure { rows = TranscriptRows.build(t, edits: edits) }
        #expect(rows.count == 3600, "speaker change at the last word splits each segment")
        #expect(build < .milliseconds(500), "row build \(build)")
        let (store, root) = try tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.upsertMeeting(Meeting(id: m, title: "Long", createdAt: Date(), captureState: .captured, duration: .seconds(7200)))
        try store.publishTranscript(t)
        for e in edits.prefix(20) { try store.appendEdit(e) }
        var d: MeetingDetail?
        let load = try clock.measure { d = try MeetingDetail.load(store, m) }
        #expect(d?.rows.count == 3600)
        #expect(load < .seconds(2), "detail load \(load)")
        // One interactive text correction on the two-hour meeting: store write + search reindex + detail reload.
        let edit = UserEdit(meetingID: m, baseRevisionID: t.id, sequence: 1_000, createdAt: Date(),
                            operation: .correctText(WordRange(revisionID: t.id, first: WordID("w5-0"), last: WordID("w5-1")), replacement: "edited"))
        let editTime = try clock.measure {
            try store.appendEdit(edit)
            d = try MeetingDetail.load(store, m)
        }
        #expect(d?.rows.contains { $0.text.hasPrefix("edited") } == true)
        #expect(editTime < .seconds(3), "edit round trip \(editTime)")
        print("[ui-perf] 2 h transcript: rows \(build), detail load from store \(load), one correction round trip \(editTime) (debug build; runs off the main thread in the app)")
    }
}
