import Testing
import Foundation
import Domain
import Storage
@testable import Presentation

/// T92: notes typed while recording become user lines of the meeting's notes, with the time each was first typed.
@Suite("Recording notes")
struct RecordingNotesTests {
    @Test func linesKeepTheTimeTheyWereFirstTyped() {
        var n = RecordingNotes()
        n.update("Ask Dana", at: 12)
        n.update("Ask Dana about notarization", at: 15)        // edited: still first typed at 12
        n.update("Ask Dana about notarization\n", at: 20)      // an empty new line has no time yet
        n.update("Ask Dana about notarization\n- earlier project: Lyon", at: 31)
        #expect(n.blocks.map(\.text) == ["Ask Dana about notarization", "earlier project: Lyon"])
        #expect(n.blocks.map(\.author) == [.user(typedAt: 12), .user(typedAt: 31)])
        #expect(n.blocks.map(\.kind) == [.paragraph, .bullet])
        let ids = n.blocks.map(\.id)
        n.update("New first line\nAsk Dana about notarization\n- earlier project: Lyon (2024)", at: 40)
        #expect(n.blocks.map(\.author) == [.user(typedAt: 40), .user(typedAt: 12), .user(typedAt: 31)], "inserted above; the edit keeps its time")
        #expect(Array(n.blocks.map(\.id).suffix(2)) == ids)
    }

    /// Acceptance: after Stop the lines are in the meeting's notes with their times, and generation cites or keeps them.
    @Test func typedLinesAreInTheNotesAfterStopAndSurviveGeneration() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "amr-recnotes-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let id = MeetingID("m-live")
        try store.upsertMeeting(Meeting(id: id, title: "Client call", createdAt: Date(), captureState: .recording))
        var n = RecordingNotes()
        n.update("Earlier project = Lyon rollout", at: 75)
        #expect(try n.save(for: id, in: store))
        #expect(try !n.save(for: id, in: store), "unchanged: no new revision")
        n.update("Earlier project = Lyon rollout\nbudget is tight", at: 140)
        n.update("budget is tight", at: 150)                   // the first line deleted
        #expect(try n.save(for: id, in: store))
        let doc = try #require(try store.currentNotesDocument(id))
        #expect(doc.userBlocks.map(\.text) == ["budget is tight"])
        #expect(doc.userBlocks[0].author == .user(typedAt: 140), "the remaining line keeps its own time")
        #expect(try store.notesDocumentRevisions(id).count == 2)

        // Generation after Stop reads this snapshot; an item cites nothing typed, so the line is kept under Also noted.
        let spoken = EvidenceRef.transcript(TranscriptEvidence(revisionID: RevisionID("tr"), segmentID: .init("s"), firstWord: .init("a"), lastWord: .init("b")))
        let s = SummaryRevision(meetingID: id, transcriptRevisionID: RevisionID("tr"), editSequence: 0, createdAt: Date(),
                                producer: ProducerInfo(component: "t", configHash: "t"), promptVersion: "notes-v4",
                                content: SummaryContent(overview: [SummaryItem(kind: .overview, text: "A client call.", evidence: [spoken])]),
                                validation: SummaryValidationReport(status: .valid), notesRevisionID: doc.id)
        #expect(try store.publishSummary(s))
        let after = try #require(try store.currentNotesDocument(id))
        #expect(after.blocks.compactMap(\.section) == [.overview, .alsoNoted])
        #expect(after.userBlocks == doc.userBlocks, "word for word, with the typed-at time")
    }

    /// Lines the recording did not write (e.g. typed in the Notes tab meanwhile) are kept in place.
    @Test func otherLinesAreLeftAlone() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "amr-recnotes-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let id = MeetingID("m-live2")
        try store.upsertMeeting(Meeting(id: id, title: "Call", createdAt: Date(), captureState: .recording))
        let other = NotesComposer.userBlocks(fromText: "from the Notes tab")
        try store.saveNotesDocument(NotesDocumentRevision(meetingID: id, createdAt: Date(), origin: .edited, blocks: other))
        var n = RecordingNotes()
        n.update("live line", at: 5)
        try n.save(for: id, in: store)
        #expect(try store.currentNotesDocument(id)?.blocks.map(\.text) == ["from the Notes tab", "live line"])
        n.update("", at: 9)
        try n.save(for: id, in: store)
        #expect(try store.currentNotesDocument(id)?.blocks.map(\.text) == ["from the Notes tab"])
    }
}
