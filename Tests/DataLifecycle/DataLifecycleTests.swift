import Foundation
import Testing
@testable import Storage
@testable import Export
import ProcessingCore
import Domain

/// A stored meeting with audio files, a published transcript (marker word inside), a summary, user notes and a
/// private scratchpad.
struct LifecycleFixture {
    let root: URL
    let store: MeetingStore
    let meeting: MeetingID
    let transcript: TranscriptRevision
    let marker: String

    init(marker: String = "zanzibarquokka", title: String = "Roadmap sync") throws {
        root = FileManager.default.temporaryDirectory.appending(path: "amr-life-\(UUID())")
        store = try MeetingStore(root: root)
        self.marker = marker
        let m = MeetingID()
        meeting = m
        try store.upsertMeeting(Meeting(id: m, title: title, createdAt: Date(), captureState: .captured, duration: .seconds(120)))
        // Two committed audio files on disk.
        var segs: [AudioSegmentRecord] = []
        for i in 0..<2 {
            let rel = "audio/systemOutput/0000/\(String(format: "%08d", i)).caf"
            let url = store.meetingDirectory(m).appending(path: rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: UInt8(i), count: 4096).write(to: url)
            segs.append(AudioSegmentRecord(meetingID: m, source: .systemOutput, epochID: EpochID(), sequence: Int64(i),
                                           format: AudioFormat(sampleRate: 48_000, channelCount: 1, sampleFormat: .float32), firstFrameInEpoch: Int64(i) * 96_000,
                                           frameCount: 96_000, interval: .seconds(Double(i) * 2, Double(i) * 2 + 2), relativePath: rel,
                                           sha256: String(repeating: "a", count: 64), state: .committed))
        }
        try store.insertSegments(segs)
        try FileManager.default.createDirectory(at: store.workDirectory(m).appending(path: "prepare-x"), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 2048).write(to: store.workDirectory(m).appending(path: "prepare-x/systemOutput-16k.wav"))
        try "checkpoint text with \(marker)".write(to: store.workDirectory(m).appending(path: "prepare-x/w0.json"), atomically: true, encoding: .utf8)
        // Transcript: Speaker 1 says the marker; one word has no speaker; a 30 s failed region.
        let s1 = Speaker(id: SpeakerID("spk1"), label: "Speaker 1", displayName: "Dana")
        let words1 = ["we", "ship", "the", marker, "build", "on", "thursday"].enumerated().map { i, w in
            Word(id: WordID("a\(i)"), text: w, interval: .seconds(1 + Double(i) * 0.3, 1.25 + Double(i) * 0.3), source: .systemOutput, speaker: .speaker(s1.id))
        }
        let words2 = ["maybe", "later"].enumerated().map { i, w in
            Word(id: WordID("b\(i)"), text: w, interval: .seconds(70 + Double(i) * 0.3, 70.25 + Double(i) * 0.3), source: .microphone, speaker: .unknown)
        }
        transcript = TranscriptRevision(id: RevisionID("tr-a"), meetingID: m, kind: .final, stage: .attributed, createdAt: Date(),
                                        producer: ProducerInfo(component: "t", configHash: "t"),
                                        segments: [TranscriptSegment(id: TranscriptSegmentID("s0"), source: .systemOutput, interval: .seconds(1, 3.4), words: words1, speaker: .speaker(s1.id)),
                                                   TranscriptSegment(id: TranscriptSegmentID("s1"), source: .microphone, interval: .seconds(70, 70.6), words: words2)],
                                        coverage: [CoverageRegion(source: .systemOutput, interval: .seconds(0, 30), status: .transcribed),
                                                   CoverageRegion(source: .systemOutput, interval: .seconds(30, 60), status: .failed),
                                                   CoverageRegion(source: .systemOutput, interval: .seconds(60, 120), status: .transcribed)],
                                        speakers: [s1])
        try store.publishTranscript(transcript)
        let ev = EvidenceRef.transcript(TranscriptEvidence(revisionID: transcript.id, segmentID: TranscriptSegmentID("s0"), firstWord: WordID("a0"), lastWord: WordID("a6")))
        let pad = ScratchpadRevision(id: RevisionID("pad-1"), meetingID: m, text: "PRIVATE-PAD remember to ask about hiring", includeInSummary: true, createdAt: Date())
        try store.saveScratchpad(pad)
        try store.publishSummary(SummaryRevision(meetingID: m, transcriptRevisionID: transcript.id, editSequence: 0, createdAt: Date(),
                                                 producer: ProducerInfo(component: "t", configHash: "t"), promptVersion: "notes-v1",
                                                 content: SummaryContent(decisions: [SummaryItem(kind: .decision, text: "Ship the \(marker) build on Thursday", evidence: [ev], uncertain: true)],
                                                                         actionItems: [SummaryItem(kind: .actionItem, text: "Dana prepares the release", evidence: [ev], owner: "Dana", due: DueDate(originalText: "by Thursday"))]),
                                                 validation: SummaryValidationReport(status: .valid), scratchpadRevisionID: pad.id, influencedByPersonalNotes: true))
        try store.saveManualNotes(ManualNotesRevision(meetingID: m, basedOnSummaryRevisionID: nil, markdown: "My own note: call the vendor", createdAt: Date()))
    }

    func input() throws -> ExportInput {
        ExportInput(meeting: try store.meeting(meeting)!, transcript: transcript, summary: try store.currentSummary(meeting),
                    userNotes: try store.latestManualNotes(meeting), scratchpad: try store.latestScratchpad(meeting))
    }

    /// True if `needle` occurs anywhere in the database files' raw bytes.
    func databaseContains(_ needle: String) throws -> Bool {
        for name in ["amaranth.sqlite", "amaranth.sqlite-wal"] {
            if let d = try? Data(contentsOf: root.appending(path: name)), d.range(of: Data(needle.utf8)) != nil { return true }
        }
        return false
    }
}

@Suite("Export")
struct ExportTests {
    @Test func exportsSelectedRevisionsWithTimestampsSpeakersAndGapsButNoScratchpadByDefault() throws {
        let f = try LifecycleFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let input = try f.input()
        for text in [Exporter.text(input), Exporter.markdown(input)] {
            #expect(text.contains("[00:00:01]") && text.contains("Dana") && text.contains(f.marker))
            #expect(text.contains("Unknown speaker") && text.contains("mic"), "unknown speakers and sources stay explicit")
            #expect(text.contains("00:00:30–00:01:00") && text.contains("speech could not be transcribed"), "gaps are listed, not omitted")
            #expect(text.contains("owner: Dana") && text.contains("due: by Thursday") && text.contains("uncertain"))
            #expect(text.contains("private personal notes"), "notes influenced by personal notes are disclosed")
            #expect(!text.contains("PRIVATE-PAD"), "the private scratchpad is excluded by default")
            #expect(text.contains("call the vendor"))
            #expect(!text.localizedCaseInsensitiveContains("topics"), "no Topics section without topics (T23)")
        }
        // T23: notes no longer have topics, but an older revision that has them still exports them.
        var old = try #require(input.summary)
        old.content.topics = [SummaryItem(kind: .topic, title: "Release timing", text: "When to ship", evidence: old.content.decisions[0].evidence)]
        let oldInput = ExportInput(meeting: input.meeting, transcript: input.transcript, summary: old, userNotes: input.userNotes)
        for text in [Exporter.text(oldInput), Exporter.markdown(oldInput)] { #expect(text.localizedCaseInsensitiveContains("topics") && text.contains("Release timing") && text.contains("When to ship")) }
        // Injected Markdown in spoken text stays inert text (no links, images or HTML in the export).
        var hostile = f.transcript
        hostile.segments[0].words[0].text = "![x](http://example.com/p.png) <img src=x> [click](http://evil)"
        let md = Exporter.markdown(ExportInput(meeting: input.meeting, transcript: hostile))
        #expect(!md.contains("![x](") && !md.contains("<img") && !md.contains("[click]("))
        var opts = ExportOptions(); opts.includeScratchpad = true
        #expect(Exporter.markdown(input, options: opts).contains("PRIVATE-PAD"))

        // JSON: versioned, decodable, verbatim selected revisions; scratchpad absent unless chosen.
        let data = try Exporter.json(input)
        let doc = try JSONDecoder.iso.decode(Exporter.JSONDocument.self, from: data)
        #expect(doc.format == "amaranth-export" && doc.version == 1)
        #expect(doc.transcript.id == f.transcript.id && doc.transcript.segments == f.transcript.segments
                 && doc.transcript.coverage == f.transcript.coverage && doc.transcript.speakers == f.transcript.speakers)
        #expect(doc.summary?.id == input.summary?.id && doc.summary?.content == input.summary?.content && doc.scratchpad == nil)
        #expect(doc.speakers["spk1"] == "Dana")
        #expect(String(decoding: data, as: UTF8.self).contains("PRIVATE-PAD") == false)

        // A newer transcript does not leak into an export of the selected one; stale notes are labelled.
        var newer = f.transcript
        newer.id = RevisionID("tr-b"); newer.segments[0].words[1].text = "NEWERWORD"
        try f.store.publishTranscript(newer)
        let staleInput = ExportInput(meeting: try f.store.meeting(f.meeting)!, transcript: f.transcript, summary: try f.store.currentSummary(f.meeting))
        let txt = Exporter.text(staleInput)
        #expect(!txt.contains("NEWERWORD"))
        #expect(txt.contains("earlier version of the transcript"))
    }

    /// T49: people show under the title in TXT/MD and travel in the JSON meeting; without them exports are unchanged.
    @Test func exportsListPeopleOnlyWhenTheMeetingHasThem() throws {
        let f = try LifecycleFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let plain = try f.input()
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let before = (Exporter.text(plain), Exporter.markdown(plain), try Exporter.json(plain, exportedAt: at))
        #expect(!before.0.contains("People:") && !before.1.contains("People:"))
        #expect(!String(decoding: before.2, as: UTF8.self).contains("\"people\"") && !String(decoding: before.2, as: UTF8.self).contains("linkedEvent"))

        try f.store.setPeople([Person(name: "Ana Ruiz"), Person(name: "Ben_O'Neil", source: .calendar)], for: f.meeting)
        let event = LinkedEvent(identifier: "EK-1", title: "Roadmap sync", start: at, end: at.addingTimeInterval(1800), calendarName: "Work")
        try f.store.setLinkedEvent(event, for: f.meeting)
        let withPeople = try f.input()
        let txt = Exporter.text(withPeople).components(separatedBy: "\n")
        #expect(txt[0] == "Roadmap sync" && txt[1] == "People: Ana Ruiz, Ben_O'Neil")
        let md = Exporter.markdown(withPeople).components(separatedBy: "\n")
        #expect(md[0] == "# Roadmap sync" && md[2] == "People: Ana Ruiz, Ben\\_O'Neil", "names are escaped like other text")
        let doc = try JSONDecoder.iso.decode(Exporter.JSONDocument.self, from: Exporter.json(withPeople, exportedAt: at))
        #expect(doc.meeting.people == withPeople.meeting.people && doc.meeting.linkedEvent == event)

        // Clearing people restores the original exports byte for byte.
        try f.store.setPeople([], for: f.meeting)
        try f.store.setLinkedEvent(nil, for: f.meeting)
        let cleared = try f.input()
        #expect(Exporter.text(cleared) == before.0 && Exporter.markdown(cleared) == before.1)
        #expect(try Exporter.json(cleared, exportedAt: at) == before.2)
    }

    @Test func audioIsExportedOnlyWhenAskedLosslessWithGapsListed() throws {
        let f = try LifecycleFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let out = f.root.appending(path: "export-audio")
        let gap = CaptureEvent(meetingID: f.meeting, source: .systemOutput, interval: .seconds(4, 6), kind: .gap, reasonCode: "device.lost", recoverable: true)
        let manifest = try Exporter.exportAudio(meetingDirectory: f.store.meetingDirectory(f.meeting), meetingID: f.meeting,
                                                segments: try f.store.segments(f.meeting), events: [gap], to: out)
        #expect(manifest.files.count == 2 && manifest.gaps.count == 1)
        for file in manifest.files {
            let orig = try f.store.segments(f.meeting).first { $0.interval.start == file.start }!
            #expect(try Data(contentsOf: out.appending(path: file.path)) == Data(contentsOf: f.store.meetingDirectory(f.meeting).appending(path: orig.relativePath)))
        }
        #expect(FileManager.default.fileExists(atPath: out.appending(path: "manifest.json").path))
    }
}

@Suite("Search and deletion", .serialized)
struct SearchAndDeletionTests {
    @Test func searchCoversTranscriptNotesTitlesAndUserNotesButNotTheScratchpad() throws {
        let f = try LifecycleFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let hits = try f.store.search(f.marker)
        #expect(Set(hits.map(\.kind)) == [.transcript, .notes])
        let t = try #require(hits.first { $0.kind == .transcript })
        #expect(t.meetingID == f.meeting && t.start == .seconds(1) && t.snippet.contains("[\(f.marker)]") && t.meetingTitle == "Roadmap sync")
        #expect(try f.store.search("roadmap").contains { $0.kind == .title })
        #expect(try f.store.search("vendor").contains { $0.kind == .userNotes })
        #expect(try f.store.search("PRIVATE-PAD hiring").isEmpty, "the private scratchpad is not indexed")
        #expect(try f.store.search("thurs").contains { $0.kind == .transcript }, "prefix search")
        // User input cannot inject FTS syntax.
        #expect(throws: Never.self) { _ = try f.store.search("\" OR NEAR( * ) AND -") }
        // Title edits are reflected; rebuild reproduces the same rows.
        var m = try f.store.meeting(f.meeting)!; m.title = "Quarterly planning"; try f.store.upsertMeeting(m)
        #expect(try f.store.search("roadmap").isEmpty && !f.store.search("quarterly").isEmpty)
        let before = try f.store.searchRowCount(f.meeting)
        try f.store.rebuildSearchIndex()
        #expect(try f.store.searchRowCount(f.meeting) == before)
    }

    @Test func audioOnlyDeletionKeepsTextSearchableAndDisablesPlaybackAndRetranscription() throws {
        let f = try LifecycleFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let before = f.store.diskUsage(f.meeting)
        #expect(before.originalAudioBytes >= 8192 && before.derivedBytes >= 2048)
        let scheduler = JobScheduler(store: f.store, executor: NoopExecutor(), configuration: .init(asrConfigHash: "a", diarizationConfigHash: "d"))
        try scheduler.deleteAudio(f.meeting)
        let m = try #require(try f.store.meeting(f.meeting))
        #expect(m.audio == .deletedByUser && !m.canPlayAudio && m.deletedAt == nil)
        #expect(try f.store.segments(f.meeting).isEmpty)
        #expect(f.store.diskUsage(f.meeting).originalAudioBytes == 0)
        let leftover = FileManager.default.enumerator(at: f.store.workDirectory(f.meeting), includingPropertiesForKeys: nil)?.allObjects.compactMap { $0 as? URL } ?? []
        #expect(!leftover.contains { ["wav", "caf"].contains($0.pathExtension) }, "no audio derivative remains")
        #expect(!FileManager.default.fileExists(atPath: f.store.meetingDirectory(f.meeting).path))
        #expect(try f.store.transcriptRevision(f.transcript.id) != nil && f.store.currentSummary(f.meeting) != nil)
        #expect(!(try f.store.search(f.marker)).isEmpty, "text stays searchable")
        #expect(throws: JobFailure.self) { try scheduler.enqueuePipeline(f.meeting) }
    }

    @Test func completeDeletionLeavesNoContentRowsFilesSearchEntriesOrBytes() throws {
        let f = try LifecycleFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(try f.databaseContains(f.marker), "precondition: the marker is stored")
        // T49 metadata goes too: people names, the event snapshot and its identifier column.
        try f.store.setPeople([Person(name: "Quillon Brightwater")], for: f.meeting)
        try f.store.setLinkedEvent(LinkedEvent(identifier: "EK-zephyrbadger", title: "Velvetquartz review", start: Date(), end: Date()), for: f.meeting)
        let scheduler = JobScheduler(store: f.store, executor: NoopExecutor(), configuration: .init(asrConfigHash: "a", diarizationConfigHash: "d"))
        try scheduler.delete(f.meeting)
        #expect(try f.store.meetings().isEmpty)
        #expect(try f.store.search(f.marker).isEmpty && f.store.search("roadmap").isEmpty && f.store.searchRowCount(f.meeting) == 0)
        #expect(try f.store.transcriptRevisions(f.meeting).isEmpty && f.store.summaryRevisions(f.meeting).isEmpty)
        #expect(try f.store.latestScratchpad(f.meeting) == nil && f.store.latestManualNotes(f.meeting) == nil && f.store.segments(f.meeting).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.store.meetingDirectory(f.meeting).path))
        #expect(!FileManager.default.fileExists(atPath: f.store.workDirectory(f.meeting).path), "checkpoints holding transcript text are gone")
        // Late worker results cannot resurrect anything.
        #expect(try f.store.publishTranscript(f.transcript) == false)
        #expect(try f.store.publishSummary(SummaryRevision(meetingID: f.meeting, transcriptRevisionID: f.transcript.id, editSequence: 0, createdAt: Date(),
                                                          producer: ProducerInfo(component: "t", configHash: "t"), promptVersion: "v",
                                                          content: SummaryContent(), validation: SummaryValidationReport(status: .valid))) == false)
        // Nothing of the meeting's content remains in the database file bytes, and after relaunch nothing is found.
        #expect(try !f.databaseContains(f.marker))
        #expect(try !f.databaseContains("Roadmap sync") && !f.databaseContains("call the vendor") && !f.databaseContains("PRIVATE-PAD"))
        #expect(try !f.databaseContains("Quillon Brightwater") && !f.databaseContains("zephyrbadger") && !f.databaseContains("Velvetquartz"))
        let reopened = try MeetingStore(root: f.root)
        #expect(try reopened.search(f.marker).isEmpty && reopened.meetings().isEmpty)
        #expect(try reopened.meeting(f.meeting)?.deletedAt != nil, "a scrubbed tombstone remains")
        #expect(try reopened.meeting(f.meeting)?.title == "")
    }
}

final class NoopExecutor: JobExecutor, @unchecked Sendable {
    func execute(_ job: JobDescriptor, progress: @escaping @Sendable (WorkerProgress) -> Void) async throws -> WorkerResponse { .cancelled(jobID: job.jobID) }
    func cancel(_ job: JobID) {}
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: s)!
        }
        return d
    }
}
