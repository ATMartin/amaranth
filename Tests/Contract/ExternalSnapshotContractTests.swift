import Foundation
import Testing
import Domain
import Storage
import MeetingAccess

/// T97: the external schema (`amaranth-meeting` v1) is frozen by a golden fixture. A change to the payload's shape
/// fails here: bump `ExternalSchema.version`, keep the old fixture decoding, and add a new one
/// (regenerate with `AMARANTH_UPDATE_FIXTURES=1 swift test --filter ExternalSnapshotContract`).
@Suite("External snapshot contract")
struct ExternalSnapshotContractTests {
    static let fixtureDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")

    /// Fixed records covering a renamed speaker, a correction, a deleted line, a trim, an overlap, a gap, uncertain and
    /// stale generated lines, a user line cited by a generated one, and a filed meeting with people.
    static func records() -> MeetingSourceRecords {
        let m = MeetingID("0e7c1a52-6f0b-4f43-9a51-4b8f1f0c2d11")
        let rev = RevisionID("rev-final-1")
        let s1 = SpeakerID("spk-1"), s2 = SpeakerID("spk-2")
        func w(_ id: String, _ text: String, _ t: Double, _ src: SourceKind = .systemOutput, who: SpeakerAssignment) -> Word {
            Word(id: WordID(id), text: text, interval: .seconds(t, t + 0.4), source: src, speaker: who)
        }
        let segs = [
            TranscriptSegment(id: TranscriptSegmentID("seg-a"), source: .systemOutput, interval: .seconds(2, 3.4),
                              words: [w("a1", "warmup", 2, who: .speaker(s1)), w("a2", "talk", 3, who: .speaker(s1))], speaker: .speaker(s1)),
            TranscriptSegment(id: TranscriptSegmentID("seg-b"), source: .systemOutput, interval: .seconds(10, 11.4),
                              words: [w("b1", "ship", 10, who: .speaker(s1)), w("b2", "frobnitz", 10.5, who: .speaker(s1)), w("b3", "friday", 11, who: .speaker(s1))], speaker: .speaker(s1)),
            TranscriptSegment(id: TranscriptSegmentID("seg-c"), source: .systemOutput, interval: .seconds(20, 21.4),
                              words: [w("c1", "drop", 20, who: .speaker(s2)), w("c2", "this", 21, who: .speaker(s2))], speaker: .speaker(s2)),
            TranscriptSegment(id: TranscriptSegmentID("seg-d"), source: .microphone, interval: .seconds(30, 31.4),
                              words: [w("d1", "sounds", 30, .microphone, who: .multiple([s1, s2])), w("d2", "good", 31, .microphone, who: .multiple([s1, s2]))],
                              speaker: .multiple([s1, s2]), flags: [.overlap]),
        ]
        let transcript = TranscriptRevision(id: rev, meetingID: m, kind: .final, stage: .attributed, createdAt: Date(timeIntervalSince1970: 1_800_000_100),
                                            producer: ProducerInfo(component: "fixture", configHash: "x"), segments: segs,
                                            coverage: [CoverageRegion(source: .systemOutput, interval: .seconds(0, 40), status: .transcribed),
                                                       CoverageRegion(source: .systemOutput, interval: .seconds(40, 55), status: .missingAudio)],
                                            speakers: [Speaker(id: s1, label: "Speaker 1"), Speaker(id: s2, label: "Speaker 2", displayName: "Rae")])
        let at = Date(timeIntervalSince1970: 1_800_000_200)
        func edit(_ n: Int, _ op: EditOperation) -> UserEdit {
            UserEdit(id: EditID("edit-\(n)"), meetingID: m, baseRevisionID: rev, sequence: n, createdAt: at, operation: op)
        }
        let edits = [
            edit(1, .renameSpeaker(s1, displayName: "Dana")),
            edit(2, .correctText(WordRange(revisionID: rev, first: WordID("b2"), last: WordID("b2")), replacement: "the build")),
            edit(3, .deleteText(WordRange(revisionID: rev, first: WordID("c1"), last: WordID("c2")))),
            edit(4, .trimTranscript(start: .seconds(5), end: nil)),
        ]
        let docID = RevisionID("notes-rev-2")
        let userLine = NoteBlock(id: NoteBlockID("blk-user"), kind: .paragraph, text: "Ask Rae about the venue", author: .user(typedAt: 31.5))
        let notes = NotesDocumentRevision(id: docID, meetingID: m, createdAt: at, basedOnSummaryRevisionID: RevisionID("sum-1"), origin: .edited, blocks: [
            NoteBlock(id: NoteBlockID("h-dec"), kind: .heading, text: "Decisions", section: .decisions, author: .model(summaryItemID: nil, uncertain: false)),
            NoteBlock(id: NoteBlockID("item-1"), kind: .paragraph, text: "Ship the build on Friday", author: .model(summaryItemID: SummaryItemID("item-1"), uncertain: false),
                      evidence: [.transcript(TranscriptEvidence(revisionID: rev, segmentID: TranscriptSegmentID("seg-b"), firstWord: WordID("b1"), lastWord: WordID("b3")))]),
            NoteBlock(id: NoteBlockID("item-2"), kind: .bullet, text: "Drop the old plan", detail: "Rae  ·  no date stated",
                      author: .model(summaryItemID: SummaryItemID("item-2"), uncertain: true),
                      evidence: [.transcript(TranscriptEvidence(revisionID: rev, segmentID: TranscriptSegmentID("seg-c"), firstWord: WordID("c1"), lastWord: WordID("c2"))),
                                 .userNote(NoteEvidence(revisionID: RevisionID("notes-rev-1"), blockID: NoteBlockID("blk-user")))]),
            NoteBlock(id: NoteBlockID("item-3"), kind: .bullet, text: "Older idea", author: .model(summaryItemID: SummaryItemID("item-3"), uncertain: false),
                      evidence: [.transcript(TranscriptEvidence(revisionID: RevisionID("rev-old"), segmentID: TranscriptSegmentID("seg-x"), firstWord: WordID("x1"), lastWord: WordID("x2")))]),
            userLine,
        ])
        var summary = SummaryRevision(id: RevisionID("sum-1"), meetingID: m, transcriptRevisionID: rev, editSequence: 0, createdAt: at,
                                      producer: ProducerInfo(component: "fixture", configHash: "x"), promptVersion: "notes-v9",
                                      content: SummaryContent(decisions: [SummaryItem(kind: .decision, text: "ORIGINAL BODY never exported", evidence: [])]),
                                      validation: SummaryValidationReport(status: .valid))
        summary.isStale = true
        let meeting = Meeting(id: m, title: "Q4 \"launch\": plan\nweek 2 — café", createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                              clock: SessionClock(utcOrigin: Date(timeIntervalSince1970: 1_800_000_000.25), timeZoneIdentifier: "Europe/Berlin", hostTimeOriginNanos: 1),
                              captureState: .captured, duration: .seconds(60),
                              currentTranscriptRevisionID: rev, currentSummaryRevisionID: RevisionID("sum-1"),
                              people: [Person(name: "Dana", source: .calendar, email: "dana@example.com"), Person(name: "Rae")],
                              folderID: FolderID("folder-1"))
        return MeetingSourceRecords(meeting: meeting, folder: Folder(id: FolderID("folder-1"), name: "Clients", createdAt: at), transcript: transcript,
                                    edits: edits, notes: notes, notesSummary: summary)
    }

    static func encoded() throws -> String {
        let s = SnapshotBuilder.build(records(), libraryID: "6f1d6a10-3a4e-4d8e-8f0e-9a7c5b4e3d21", readAt: Date(timeIntervalSince1970: 1_800_001_000))
        return String(decoding: try ExternalCoding.encoder().encode(s), as: UTF8.self) + "\n"
    }

    @Test func snapshotV1MatchesTheGoldenFixture() throws {
        let url = Self.fixtureDir.appending(path: "meeting-snapshot-v1.json")
        let now = try Self.encoded()
        if ProcessInfo.processInfo.environment["AMARANTH_UPDATE_FIXTURES"] == "1" {
            try now.write(to: url, atomically: true, encoding: .utf8)
        }
        let golden = try String(contentsOf: url, encoding: .utf8)
        #expect(now == golden, "external schema changed: bump ExternalSchema.version and add a fixture")
        #expect(!golden.contains("ORIGINAL BODY") && !golden.contains("dana@example.com") && !golden.contains("frobnitz")
                && !golden.contains("warmup") && !golden.contains("drop this"))
    }

    @Test func everyFixtureVersionStillDecodes() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.fixtureDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("meeting-snapshot-v") }
        #expect(!files.isEmpty)
        for f in files {
            let s = try ExternalCoding.decoder().decode(MeetingSnapshot.self, from: Data(contentsOf: f))
            #expect(s.format == "amaranth-meeting" && s.version <= ExternalSchema.version)
            #expect(SnapshotBuilder.fingerprint(s) == s.fingerprint, "\(f.lastPathComponent) fingerprint")
        }
    }
}
