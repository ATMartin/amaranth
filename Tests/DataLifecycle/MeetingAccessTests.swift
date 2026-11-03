import Foundation
import Testing
@testable import Storage
import Domain
import MeetingAccess

/// T97 (spec 0009 §1): a meeting whose transcript has a renamed speaker, a corrected word, a deleted line, both trims,
/// an overlap and a failed stretch; generated notes (one uncertain, one citing the deleted line) made before those
/// edits, one generated line the user rewrote, and a line the user typed. Every word the user removed, the generated
/// summary's original body and an attendee email are planted markers that must never leave through the snapshot.
struct AccessFixture {
    static let hidden = ["HIDDENTRIMSTART", "HIDDENCORRECT", "HIDDENDELETE", "HIDDENTRIMEND", "SUMMARYBODYONLY", "ana-secret@example.com"]
    let root: URL
    let store: MeetingStore
    let reader: MeetingReader
    let meeting: MeetingID
    let transcript: TranscriptRevision
    let spk1 = SpeakerID("spk1"), spk2 = SpeakerID("spk2")
    private(set) var sequence = 0

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "amr-access-\(UUID())")
        store = try MeetingStore(root: root)
        reader = MeetingReader(store: store)
        let m = MeetingID()
        meeting = m
        try store.upsertMeeting(Meeting(id: m, title: "Kestrel launch", createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                                        clock: SessionClock(utcOrigin: Date(timeIntervalSince1970: 1_800_000_000), timeZoneIdentifier: "America/Chicago", hostTimeOriginNanos: 0),
                                        captureState: .captured, duration: .seconds(120)))
        try store.setPeople([Person(name: "Ana", source: .calendar, email: "ana-secret@example.com"), Person(name: "Ben")], for: m)
        func words(_ prefix: String, _ texts: [String], at t: Double, _ source: SourceKind = .systemOutput, _ who: SpeakerAssignment) -> [Word] {
            texts.enumerated().map { i, w in
                Word(id: WordID("\(prefix)\(i)"), text: w, interval: .seconds(t + Double(i) * 0.3, t + Double(i) * 0.3 + 0.25), source: source, speaker: who)
            }
        }
        func seg(_ id: String, _ w: [Word]) -> TranscriptSegment {
            TranscriptSegment(id: TranscriptSegmentID(id), source: w[0].source, interval: SessionInterval(unchecked: w.first!.interval.start, w.last!.interval.end), words: w, speaker: w[0].speaker)
        }
        let s0 = seg("s0", words("a", ["HIDDENTRIMSTART", "chatter"], at: 1, .systemOutput, .speaker(spk1)))
        let s1 = seg("s1", words("c", ["we", "ship", "the", "HIDDENCORRECT", "build", "thursday"], at: 10, .systemOutput, .speaker(spk1)))
        let s2 = seg("s2", words("d", ["HIDDENDELETE", "secret", "plan"], at: 20, .systemOutput, .speaker(spk2)))
        let s3 = seg("s3", words("e", ["budget", "review", "next", "week"], at: 30, .systemOutput, .speaker(spk2)))
        let s4 = seg("s4", words("f", ["yes", "agreed"], at: 40, .microphone, .multiple([spk1, spk2])))
        let s5 = seg("s5", words("g", ["HIDDENTRIMEND", "goodbye"], at: 100, .systemOutput, .speaker(spk1)))
        transcript = TranscriptRevision(id: RevisionID("tr-1"), meetingID: m, kind: .final, stage: .attributed, createdAt: Date(),
                                        producer: ProducerInfo(component: "t", configHash: "t"), segments: [s0, s1, s2, s3, s4, s5],
                                        coverage: [CoverageRegion(source: .systemOutput, interval: .seconds(0, 50), status: .transcribed),
                                                   CoverageRegion(source: .systemOutput, interval: .seconds(50, 80), status: .failed),
                                                   CoverageRegion(source: .systemOutput, interval: .seconds(80, 120), status: .transcribed)],
                                        speakers: [Speaker(id: spk1, label: "Speaker 1"), Speaker(id: spk2, label: "Speaker 2")])
        try store.publishTranscript(transcript)
        func ev(_ s: TranscriptSegment) -> EvidenceRef {
            .transcript(TranscriptEvidence(revisionID: transcript.id, segmentID: s.id, firstWord: s.words.first!.id, lastWord: s.words.last!.id))
        }
        try store.publishSummary(SummaryRevision(meetingID: m, transcriptRevisionID: transcript.id, editSequence: 0, createdAt: Date(timeIntervalSince1970: 1_800_000_500),
                                                 producer: ProducerInfo(component: "t", configHash: "t"), promptVersion: "notes-v9",
                                                 content: SummaryContent(overview: [SummaryItem(id: SummaryItemID("ov"), kind: .overview, text: "The team discussed the release", evidence: [ev(s0)], uncertain: true)],
                                                                         decisions: [SummaryItem(id: SummaryItemID("dec"), kind: .decision, text: "SUMMARYBODYONLY ship the build", evidence: [ev(s1)])],
                                                                         actionItems: [SummaryItem(id: SummaryItemID("act"), kind: .actionItem, text: "Prepare the secret plan", evidence: [ev(s2)])]),
                                                 validation: SummaryValidationReport(status: .valid)))
        // The user rewrites the decision (it becomes theirs) and types a line during the recording.
        var doc = try #require(try store.currentNotesDocument(m))
        doc.id = RevisionID(); doc.origin = .edited
        let i = try #require(doc.blocks.firstIndex { $0.id.rawValue == "dec" })
        doc.blocks[i] = doc.blocks[i].editing(text: "Ship the kestrel build on Thursday")
        doc.blocks += NotesComposer.userBlocks(fromText: "Call the venue", typedAt: 12)
        try store.saveNotesDocument(doc)
    }

    mutating func edit(_ op: EditOperation) throws {
        sequence += 1
        try store.appendEdit(UserEdit(meetingID: meeting, baseRevisionID: transcript.id, sequence: sequence, createdAt: Date(), operation: op))
    }

    func range(_ first: String, _ last: String) -> WordRange { WordRange(revisionID: transcript.id, first: WordID(first), last: WordID(last)) }

    /// The user's edits after notes were generated: rename, correction, line deletion, both trims.
    mutating func applyUserEdits() throws {
        try edit(.renameSpeaker(spk1, displayName: "Dana"))
        try edit(.correctText(range("c3", "c3"), replacement: "kestrel"))
        try edit(.deleteText(range("d0", "d2")))
        try edit(.trimTranscript(start: .seconds(5), end: nil))
        try edit(.trimTranscript(start: nil, end: .seconds(90)))
    }

    func snapshot() throws -> MeetingSnapshot { try #require(try reader.snapshot(meeting)) }

    static func json(_ s: MeetingSnapshot) throws -> String { String(decoding: try ExternalCoding.encoder().encode(s), as: UTF8.self) }
}

@Suite("Meeting access snapshots (T97)")
struct MeetingSnapshotTests {
    @Test func snapshotShowsTheDisplayedTranscriptAndNotesAndNothingHidden() throws {
        var f = try AccessFixture()
        try f.applyUserEdits()
        let s = try f.snapshot()
        let json = try AccessFixture.json(s)
        for marker in AccessFixture.hidden { #expect(!json.contains(marker), "\(marker) leaked") }
        #expect(!json.contains(f.root.path), "local path leaked")
        #expect(s.format == "amaranth-meeting" && s.version == 1 && s.meetingID == f.meeting.rawValue)
        #expect(s.title == "Kestrel launch" && s.people == ["Ana", "Ben"] && s.timeZone == "America/Chicago" && s.durationNs == 120_000_000_000)
        // Transcript: trims and the deleted line are gone, the correction and rename show, overlap is explicit.
        #expect(s.transcript.map(\.text) == ["we ship the kestrel build thursday", "budget review next week", "yes agreed"])
        #expect(s.transcript.map(\.speaker) == ["Dana", "Speaker 2", "Dana + Speaker 2 (overlapping)"])
        #expect(s.transcript[0].flags == ["corrected"] && s.transcript[2].flags == ["overlap"])
        #expect(s.speakers.map(\.name) == ["Dana", "Speaker 2"])
        #expect(s.gaps.map(\.reason) == ["speech could not be transcribed"] && s.gaps[0].startNs == 50_000_000_000)
        // Notes as shown: the stale generated lines stay (with disclosure), the user's rewrite and typed line are "user".
        #expect(s.notes.filter { $0.kind != "heading" }.map(\.text) == ["The team discussed the release", "Ship the kestrel build on Thursday",
                                                                         "Prepare the secret plan", "Call the venue"])
        #expect(s.notes.filter { $0.kind != "heading" }.map(\.author) == ["model", "user", "model", "user"])
        let overview = try #require(s.notes.first { $0.blockID == "ov" })
        #expect(overview.uncertain && overview.evidence.map(\.status) == ["removed"])   // cites the trimmed start
        let action = try #require(s.notes.first { $0.blockID == "act" })
        #expect(action.evidence.map(\.status) == ["removed"] && action.evidence[0].citation == nil && action.evidence[0].startNs == nil)
        let decision = try #require(s.notes.first { $0.blockID == "dec" })
        #expect(decision.evidence.map(\.status) == ["current"] && decision.evidence[0].citation == s.transcript[0].citation)
        #expect(s.notes.first { $0.text == "Call the venue" }?.typedAtSeconds == 12)
        #expect(s.state.notesStale && s.state.transcriptLinesRemoved && s.state.transcript == "final" && s.state.notes == "ready")
        #expect(s.generatedNotes?.promptVersion == "notes-v9" && s.generatedNotes?.stale == true)
        #expect(s.limitations.contains { $0.contains("may still mention removed discussion") })
        #expect(s.limitations.contains { $0.contains("not who said") })
        #expect(s.revisions.transcript == "tr-1" && s.revisions.editSequence == 5)
        // Round trip: the payload decodes back to the same snapshot.
        let back = try ExternalCoding.decoder().decode(MeetingSnapshot.self, from: Data(json.utf8))
        #expect(back == s && SnapshotBuilder.fingerprint(back) == s.fingerprint)
    }

    @Test func notesOnlyMeetingIsValidAndSaysItHasNoTranscript() throws {
        let f = try AccessFixture()
        let m = MeetingID()
        try f.store.upsertMeeting(Meeting(id: m, title: "Hallway chat", createdAt: Date(), captureState: .idle))
        try f.store.saveNotesDocument(NotesDocumentRevision(meetingID: m, createdAt: Date(), origin: .edited,
                                                            blocks: NotesComposer.userBlocks(fromText: "# Ideas\n- Try the new venue")))
        let s = try #require(try f.reader.snapshot(m))
        #expect(s.state.transcript == "none" && s.state.notes == "ready" && s.transcript.isEmpty && s.revisions.transcript == nil)
        #expect(s.notes.map(\.text) == ["Ideas", "Try the new venue"] && s.notes.allSatisfy { $0.author == "user" })
        #expect(s.limitations.contains { $0.contains("no transcript") })
    }

    @Test func fingerprintChangesForEveryRelevantMutation() throws {
        var f = try AccessFixture()
        var seen = [try f.snapshot().fingerprint]
        func changed(_ what: String) throws {
            let fp = try f.snapshot().fingerprint
            #expect(!seen.contains(fp), "fingerprint did not change: \(what)")
            seen.append(fp)
        }
        // Reading twice changes nothing.
        #expect(try f.snapshot().fingerprint == seen[0])
        var m = try #require(try f.store.meeting(f.meeting)); m.title = "Kestrel launch (renamed)"
        try f.store.upsertMeeting(m); try changed("title")
        try f.store.setPeople([Person(name: "Ana")], for: f.meeting); try changed("people")
        let folder = try f.store.createFolder(name: "Clients")
        try f.store.moveMeeting(f.meeting, to: folder.id); try changed("folder")
        try f.store.renameFolder(folder.id, to: "Clients 2026"); try changed("folder rename")
        try f.edit(.renameSpeaker(f.spk2, displayName: "Eli")); try changed("speaker rename")
        try f.edit(.correctText(f.range("e0", "e0"), replacement: "Budget")); try changed("correction")
        try f.edit(.deleteText(f.range("f0", "f1"))); try changed("line deletion")
        try f.edit(.trimTranscript(start: .seconds(5), end: nil)); try changed("trim")
        try f.edit(.markUncertain(f.range("e1", "e1"))); try changed("other edit")
        var doc = try #require(try f.store.currentNotesDocument(f.meeting)); doc.id = RevisionID()
        doc.blocks += NotesComposer.userBlocks(fromText: "One more line")
        try f.store.saveNotesDocument(doc); try changed("notes")
        var t2 = f.transcript; t2.id = RevisionID("tr-2")
        try f.store.publishTranscript(t2); try changed("new transcript revision")
    }

    /// Edits land on another thread while snapshots are taken: each snapshot is one state (its edit sequence and the
    /// number of corrections it shows agree), never a mix of two.
    @Test func concurrentEditsYieldConsistentSnapshots() async throws {
        let f = try AccessFixture()
        let words = ["c0", "c1", "c2", "c4", "c5", "e0", "e1", "e2", "e3", "f0", "f1"]
        let store = f.store, meeting = f.meeting, revision = f.transcript.id
        let writer = Task.detached {
            for (i, w) in words.enumerated() {
                try store.appendEdit(UserEdit(meetingID: meeting, baseRevisionID: revision, sequence: i + 1, createdAt: Date(),
                                              operation: .correctText(WordRange(revisionID: revision, first: WordID(w), last: WordID(w)), replacement: "ZZ\(i)")))
            }
        }
        var observed = Set<Int>()
        while true {
            let s = try f.snapshot()
            let shown = s.transcript.map(\.text).joined(separator: " ").components(separatedBy: " ").filter { $0.hasPrefix("ZZ") }.count
            #expect(shown == s.revisions.editSequence, "snapshot mixes states")
            #expect(SnapshotBuilder.fingerprint(s) == s.fingerprint)
            observed.insert(s.revisions.editSequence)
            if s.revisions.editSequence == words.count { break }
            await Task.yield()
        }
        try await writer.value
        #expect(observed.contains(words.count))
    }

    @Test func deletedMeetingsCannotBeFetchedOrCited() throws {
        var f = try AccessFixture()
        try f.applyUserEdits()
        let citation = try f.snapshot().transcript[0].citation
        try f.store.tombstone(f.meeting)
        #expect(try f.reader.snapshot(f.meeting) == nil)
        #expect(f.reader.resolve(citation) == .unavailable)
        #expect(f.reader.resolve("amaranth://meeting/\(UUID().uuidString)") == .unavailable)
    }

    @Test func libraryIDIsStableAndPrivate() throws {
        let f = try AccessFixture()
        let a = try f.store.libraryID(), b = try MeetingStore(root: f.root).libraryID()
        #expect(a == b && UUID(uuidString: a) != nil)
        let perms = try FileManager.default.attributesOfItem(atPath: f.root.appending(path: "library-id").path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }
}

@Suite("Citation URLs (T97)")
struct CitationURLTests {
    @Test func currentTranscriptAndNotesCitationsResolve() throws {
        var f = try AccessFixture()
        try f.applyUserEdits()
        let s = try f.snapshot()
        guard case .current(let t) = f.reader.resolve(s.transcript[1].citation) else { Issue.record("transcript citation"); return }
        #expect(t.source == .transcript && t.ref == "s3" && t.word == "e0" && t.startNs == 30_000_000_000)
        let user = try #require(s.notes.first { $0.text == "Call the venue" })
        guard case .current(let n) = f.reader.resolve(user.citation) else { Issue.record("note citation"); return }
        #expect(n.source == .userNote && n.ref == user.blockID)
        guard case .current(let meeting) = f.reader.resolve(s.citation) else { Issue.record("meeting citation"); return }
        #expect(meeting.source == nil && meeting.title == "Kestrel launch")
        // A later, unrelated notes revision keeps an unchanged line citable (same text hash).
        var doc = try #require(try f.store.currentNotesDocument(f.meeting)); doc.id = RevisionID()
        doc.blocks += NotesComposer.userBlocks(fromText: "Another line")
        try f.store.saveNotesDocument(doc)
        guard case .current = f.reader.resolve(user.citation) else { Issue.record("unchanged note after new revision"); return }
    }

    @Test func changedOrDeletedSourcesSayChangedNeverAnotherLine() throws {
        var f = try AccessFixture()
        let before = try f.snapshot()
        let line = try #require(before.transcript.first { $0.segmentID == "s1" })
        let doomed = try #require(before.transcript.first { $0.segmentID == "s2" })
        try f.applyUserEdits()
        // The correction changed the line's text: changed, even though the revision is the same.
        #expect(f.reader.resolve(line.citation) == .changed(meetingID: f.meeting, title: "Kestrel launch"))
        #expect(f.reader.resolve(doomed.citation) == .changed(meetingID: f.meeting, title: "Kestrel launch"))
        // Reprocessing publishes a new revision with new segments: old citations are changed, not re-pointed.
        let current = try f.snapshot().transcript[1].citation
        var t2 = f.transcript; t2.id = RevisionID("tr-2")
        t2.segments = t2.segments.map { var s = $0; s.id = TranscriptSegmentID("n-" + s.id.rawValue); return s }
        try f.store.publishTranscript(t2)
        #expect(f.reader.resolve(current) == .changed(meetingID: f.meeting, title: "Kestrel launch"))
        // An edited note no longer matches its hash.
        let note = try #require(try f.snapshot().notes.first { $0.text == "Call the venue" })
        var doc = try #require(try f.store.currentNotesDocument(f.meeting)); doc.id = RevisionID()
        let i = try #require(doc.blocks.firstIndex { $0.id.rawValue == note.blockID })
        doc.blocks[i] = doc.blocks[i].editing(text: "Call the other venue")
        try f.store.saveNotesDocument(doc)
        #expect(f.reader.resolve(note.citation) == .changed(meetingID: f.meeting, title: "Kestrel launch"))
        // A citation of an old revision without a hash can't be checked: changed.
        let id = f.meeting.rawValue
        #expect(f.reader.resolve("amaranth://meeting/\(id)?source=transcript&ref=n-s3&word=e0&revision=tr-1") == .changed(meetingID: f.meeting, title: "Kestrel launch"))
    }

    @Test func invalidAndMaliciousURLsAreRejectedBeforeAnyLookup() throws {
        let id = UUID().uuidString.lowercased()
        let bad = [
            "", "meeting", "https://meeting/\(id)", "javascript:alert(1)", "file:///etc/passwd", "amaranth://evil/\(id)",
            "amaranth://meeting/not-a-uuid", "amaranth://meeting/\(id)/extra", "amaranth://meeting/../\(id)", "amaranth://meeting/",
            "amaranth://user:pw@meeting/\(id)", "amaranth://meeting:8080/\(id)", "amaranth://meeting/\(id)#frag",
            "amaranth://meeting/\(id)?", "amaranth://meeting/\(id)?ref=s1", "amaranth://meeting/\(id)?source=transcript&ref=s1",
            "amaranth://meeting/\(id)?source=audio&ref=s1&revision=r", "amaranth://meeting/\(id)?source=transcript&ref=s1&revision=r&cmd=rm",
            "amaranth://meeting/\(id)?source=transcript&source=notes&ref=s1&revision=r",
            "amaranth://meeting/\(id)?source=transcript&ref=s1%20OR%201&revision=r", "amaranth://meeting/\(id)?source=transcript&ref=&revision=r",
            "amaranth://meeting/\(id)?source=transcript&ref='; DROP TABLE meetings;--&revision=r",
            "amaranth://meeting/\(id)?source=transcript&ref=s1&revision=r&h=xyz", "amaranth://meeting/\(id)?source=transcript&ref=s1&revision=r", "amaranth://meeting/\(id)?source=notes&ref=b&word=w&revision=r",
            "amaranth://meeting/\(id)?source=transcript&ref=\(String(repeating: "a", count: 129))&revision=r",
            "amaranth://meeting/\(id)?source=transcript&ref=s1&revision=\(String(repeating: "r", count: 2100))",
            "amaranth://meeting/\(id)?source=transcript&ref=%2e%2e%2f&revision=r", "amaranth://meeting/\(id)?source=transcript&ref=s\u{202E}1&revision=r",
        ]
        for text in bad {
            guard case .failure(.invalidRequest) = SourceURL.parse(text) else { Issue.record("accepted: \(text.prefix(80))"); continue }
        }
        // The reader reports them as invalid without touching the store (a store-less reader would crash otherwise).
        let f = try AccessFixture()
        for text in bad { if case .invalid = f.reader.resolve(text) {} else { Issue.record("resolved: \(text.prefix(80))") } }
        // Well-formed URLs round-trip through their own text.
        let ok = SourceURL(meetingID: MeetingID(id), source: .transcript, ref: "seg-1a2b", word: "w_9", revision: "rev:3", hash: "0123456789abcdef")
        #expect(try SourceURL.parse(ok.string).get() == ok)
        #expect(try SourceURL.parse("AMARANTH://Meeting/\(id.uppercased())").get().meetingID.rawValue == id)
    }
}
