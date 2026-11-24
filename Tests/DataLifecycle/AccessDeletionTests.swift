import Foundation
import Testing
@testable import Storage
import Domain
import MeetingAccess

/// T100: deletion and late-publication races against the external read model and bulk export.
@Suite("External access and deletion (T100)")
struct AccessDeletionTests {
    @Test func audioOnlyDeletionKeepsTextAndSaysAudioIsGone() throws {
        let f = try LifecycleFixture()
        let reader = MeetingReader(store: f.store)
        try f.store.deleteAudio(f.meeting)
        let s = try #require(try reader.snapshot(f.meeting))
        #expect(s.state.audio == "deleted" && !s.transcript.isEmpty && s.limitations.contains { $0.contains("audio was deleted") })
        let d = BulkExportTests.dest()
        #expect(BulkExport.run(reader, meetings: [f.meeting], content: .notesAndTranscript, destination: d).status == .complete)
        #expect(BulkExportTests.allFiles(d).allSatisfy { !["caf", "wav"].contains($0.pathExtension) })
        #expect(BulkExportTests.read(d.appending(path: "amaranth/\(f.meeting.rawValue)/meeting.md")).contains("audio: \"deleted\""))
    }

    @Test func meetingDeletedDuringAnExportIsReportedNotWritten() throws {
        let lib = try RetrievalLibrary()
        let ids = try (0..<3).map { try lib.meeting("M\($0)", lines: ["line \($0)"]) }
        let d = BulkExportTests.dest()
        let r = BulkExport.run(lib.reader, meetings: ids, content: .notesAndTranscript, destination: d, progress: { done, _ in
            if done == 1 { try? lib.store.tombstone(ids[1]) }   // deleted after the run started
        })
        #expect(r.status == .partial && r.errors.map(\.meetingID) == [ids[1].rawValue] && r.errors[0].message.contains("deleted"))
        #expect(!FileManager.default.fileExists(atPath: d.appending(path: "amaranth/\(ids[1].rawValue)").path))
        // Deleting after an export leaves the snapshot's files (a copy), and later exports never touch them.
        try lib.store.tombstone(ids[0])
        let again = BulkExport.run(lib.reader, meetings: try BulkExport.preview(lib.reader, scope: .all).meetingIDs, content: .notesAndTranscript, destination: d)
        #expect(again.status == .complete)
        #expect(FileManager.default.fileExists(atPath: d.appending(path: "amaranth/\(ids[0].rawValue)/meeting.md").path))
    }

    /// Snapshots, searches and citations racing a deletion: before it, whole meetings; after it, nothing — and a late
    /// transcript or notes publication can't bring the meeting back.
    @Test func deletionRacesNeverResurrectOrHalfShowAMeeting() async throws {
        let lib = try RetrievalLibrary()
        let m = try lib.meeting("Doomed", lines: (0..<200).map { "doomed line \($0) zebracorn" }, notes: ["zebracorn note"])
        let citation = try #require(try lib.reader.snapshot(m)).transcript[5].citation
        let store = lib.store, reader = lib.reader
        let deleter = Task.detached { try await Task.sleep(for: .milliseconds(20)); try store.tombstone(m) }
        var seenDeleted = false
        for _ in 0..<400 {
            if let s = try reader.snapshot(m) {
                #expect(!seenDeleted, "meeting came back after deletion")
                #expect(s.transcript.count == 200 && s.notes.count == 1)   // whole, never partial
            } else { seenDeleted = true }
            if seenDeleted { break }
            await Task.yield()
        }
        try await deleter.value
        // Late results after deletion publish nothing.
        var t = TranscriptRevision(meetingID: m, kind: .final, stage: .attributed, createdAt: Date(), producer: ProducerInfo(component: "late", configHash: "x"),
                                   segments: [], coverage: [], speakers: [])
        t.id = RevisionID("late")
        #expect(try store.publishTranscript(t) == false)
        #expect(try store.saveNotesDocument(NotesDocumentRevision(meetingID: m, createdAt: Date(), origin: .edited, blocks: NotesComposer.userBlocks(fromText: "zebracorn late"))) == false)
        #expect(try reader.snapshot(m) == nil && reader.resolve(citation) == .unavailable)
        #expect(try reader.searchMeetings(SearchMeetingsRequest(query: "zebracorn")).passages.isEmpty)
        #expect(try reader.listMeetings(ListMeetingsRequest()).meetings.isEmpty)
    }
}
