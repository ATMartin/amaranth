import Foundation
import Testing
@testable import Storage
import Domain
import DomainFixtures

@Suite("Meeting store (SQLite)")
struct MeetingStoreTests {
    func tempStore() throws -> (MeetingStore, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "amr-store-\(UUID())")
        return (try MeetingStore(root: root), root)
    }

    @Test func migratesAndRoundTripsFixtureRecords() throws {
        let (store, root) = try tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        for f in Fixtures.all {
            try store.upsertMeeting(f.meeting)
            try store.insertEpochs(f.epochs)
            try store.insertSegments(f.audioSegments)
            try store.insertEvents(f.events)
            #expect(try store.meeting(f.meeting.id) == f.meeting)
            #expect(try store.segments(f.meeting.id).count == f.audioSegments.count)
            #expect(Set(try store.events(f.meeting.id)) == Set(f.events))
            #expect(Set(try store.epochs(f.meeting.id)) == Set(f.epochs))
        }
        #expect(try store.integrityOK())
        // WAL mode, foreign keys and schema version are in effect.
        let db = try SQLiteDB(path: root.appending(path: "amaranth.sqlite").path)
        #expect(try db.run("PRAGMA journal_mode").first?["journal_mode"]?.text == "wal")
        #expect(try db.run("PRAGMA user_version").first?["user_version"]?.int == Int64(Schema.migrations.count))
    }

    @Test func contentIsReadableOnlyByTheUser() throws {
        let (store, root) = try tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = store
        func perms(_ p: String) -> Int { ((try? FileManager.default.attributesOfItem(atPath: root.appending(path: p).path))?[.posixPermissions] as? Int) ?? -1 }
        #expect(perms("amaranth.sqlite") == 0o600)
        #expect(perms("meetings") == 0o700 && perms("work") == 0o700)
        // A data folder that already existed with looser permissions is tightened on open.
        let loose = FileManager.default.temporaryDirectory.appending(path: "amr-loose-\(UUID())")
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(at: loose) }
        _ = try MeetingStore(root: loose)
        #expect((try FileManager.default.attributesOfItem(atPath: loose.path)[.posixPermissions] as? Int) == 0o700)
    }

    @Test func insertsAreIdempotentForRecoveryReplays() throws {
        let (store, root) = try tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let f = Fixtures.missingSource
        try store.upsertMeeting(f.meeting)
        try store.insertSegments(f.audioSegments)
        try store.insertSegments(f.audioSegments)
        try store.insertEvents(f.events + f.events)
        #expect(try store.segments(f.meeting.id).count == f.audioSegments.count)
        #expect(try store.events(f.meeting.id).count == f.events.count)
    }

    @Test func segmentsRequireAnExistingMeeting() throws {
        let (store, root) = try tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: (any Error).self) { try store.insertSegments(Fixtures.pausedMeeting.audioSegments) }
    }

    @Test func refusesNewerSchema() throws {
        let (store, root) = try tempStore()
        _ = store
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try SQLiteDB(path: root.appending(path: "amaranth.sqlite").path)
        try db.exec("PRAGMA user_version = 99")
        #expect(throws: (any Error).self) { _ = try MeetingStore(root: root) }
    }

    @Test func indexerBatchesOffThreadAndFlushesOnStop() throws {
        let (store, root) = try tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let f = Fixtures.twoSourceConversation
        try store.upsertMeeting(f.meeting)
        let indexer = SegmentIndexer(store: store, interval: 60)
        f.epochs.forEach(indexer.add)
        f.audioSegments.forEach(indexer.add)
        #expect(try store.segments(f.meeting.id).isEmpty, "nothing written synchronously on the caller's thread")
        indexer.stop()
        #expect(try store.segments(f.meeting.id).count == f.audioSegments.count)
    }

    // MARK: T49 people and linked event

    static let event = LinkedEvent(identifier: "EK-123", title: "Roadmap sync", start: Date(timeIntervalSince1970: 1_800_000_000),
                                   end: Date(timeIntervalSince1970: 1_800_003_600), calendarName: "Work")

    @Test func peopleAndLinkedEventRoundTrip() throws {
        let (store, root) = try tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let m = Meeting(title: "Sync", createdAt: Date(timeIntervalSince1970: 1_800_000_000), people: [Person(name: "Ana", source: .calendar)],
                        linkedEvent: Self.event)
        try store.upsertMeeting(m)
        #expect(try store.meeting(m.id) == m, "a new row takes the meeting's metadata as given")
        try store.setPeople([Person(name: "  Ana "), Person(name: "ben"), Person(name: ""), Person(name: "ANA"), Person(name: "Ben")], for: m.id)
        #expect(try store.meeting(m.id)?.people == [Person(name: "Ana"), Person(name: "ben")], "trimmed, blanks and repeats dropped")
        try store.setLinkedEvent(nil, for: m.id)
        #expect(try store.meeting(m.id)?.linkedEvent == nil)
        try store.setLinkedEvent(Self.event, for: m.id)
        #expect(try store.meeting(m.id)?.linkedEvent == Self.event)
        // The event is findable by its identifier.
        let db = try SQLiteDB(path: root.appending(path: "amaranth.sqlite").path)
        #expect(try db.run("SELECT id FROM meetings WHERE linked_event_id=?", [.text("EK-123")]).first?["id"]?.text == m.id.rawValue)
        try store.setLinkedEvent(nil, for: m.id)
        #expect(try db.run("SELECT linked_event_id FROM meetings WHERE id=?", [.text(m.id.rawValue)]).first?["linked_event_id"]?.text == nil)
    }

    @Test func staleWritersKeepStoredPeople() throws {
        let (store, root) = try tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        var m = Meeting(title: "Recording", createdAt: Date(), captureState: .recording)
        try store.upsertMeeting(m)
        try store.setPeople([Person(name: "Ana")], for: m.id)
        try store.setLinkedEvent(Self.event, for: m.id)
        // The recorder still holds its copy without people and writes it on stop.
        m.captureState = .captured
        try store.upsertMeeting(m)
        let stored = try #require(try store.meeting(m.id))
        #expect(stored.captureState == .captured && stored.people == [Person(name: "Ana")] && stored.linkedEvent == Self.event)
        // Deleted meetings take no new metadata.
        try store.tombstone(m.id)
        try store.setPeople([Person(name: "Late")], for: m.id)
        #expect(try store.meeting(m.id)?.people == [Person(name: "Ana")])
        try store.setPeople([], for: MeetingID("missing"))
        #expect(try store.meeting(MeetingID("missing")) == nil)
    }

    @Test func meetingsWithoutMetadataEncodeAsBefore() throws {
        let m = Meeting(id: MeetingID("m1"), title: "Plain", createdAt: Date(timeIntervalSince1970: 0))
        let text = String(decoding: try ContractCoding.encode(m), as: UTF8.self)
        #expect(!text.contains("people") && !text.contains("linkedEvent"))
        let full = Meeting(id: MeetingID("m1"), title: "Plain", createdAt: Date(timeIntervalSince1970: 0), people: [Person(name: "Ana")], linkedEvent: Self.event)
        #expect(try ContractCoding.decode(Meeting.self, from: ContractCoding.encode(full)) == full)
    }

    /// A library written before T49 (schema v2, meeting JSON without the new keys) opens, migrates and decodes with
    /// empty people and no event, then accepts both.
    @Test func oldRowsDecodeWithEmptyPeopleAndNoEvent() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "amr-v2-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let db = try SQLiteDB(path: root.appending(path: "amaranth.sqlite").path)
            try db.exec(Schema.migrations[0])
            try db.exec(Schema.migrations[1])
            try db.exec("PRAGMA user_version = 2")
            let oldJSON = """
                {"contractVersion":1,"payload":{"audio":"present","captureState":"captured","createdAt":"2026-10-01T10:00:00Z",\
                "duration":60000000000,"id":"old-1","retention":"untilUserDeletes","selectedSources":"both","title":"Old meeting"}}
                """
            try db.run("""
                INSERT INTO meetings (id, title, created_at, capture_state, selected_sources, audio, duration_ns, json)
                VALUES ('old-1','Old meeting',0,'captured','both','present',60000000000,?)
                """, [.blob(Data(oldJSON.utf8))])
        }
        let store = try MeetingStore(root: root)
        let m = try #require(try store.meeting(MeetingID("old-1")))
        #expect(m.title == "Old meeting" && m.people.isEmpty && m.linkedEvent == nil)
        #expect(try store.meetings().map(\.id) == [MeetingID("old-1")])
        try store.setPeople([Person(name: "Ana")], for: m.id)
        #expect(try store.meeting(m.id)?.people == [Person(name: "Ana")])
    }

    // MARK: T39 folders

    @Test func folderCRUDAndNameRules() throws {
        let (store, root) = try tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let acme = try store.createFolder(name: "  Acme ")
        let hiring = try store.createFolder(name: "Hiring")
        #expect(try store.folders().map(\.name) == ["Acme", "Hiring"])
        #expect(try store.folders().map(\.sortOrder) == [0, 1])
        #expect(throws: MeetingStore.FolderError.emptyName) { try store.createFolder(name: "  \n") }
        #expect(throws: MeetingStore.FolderError.duplicateName("Acme")) { try store.createFolder(name: "ACME") }
        #expect(throws: MeetingStore.FolderError.duplicateName("Hiring")) { try store.renameFolder(acme.id, to: "hiring") }
        // Unicode case folding, beyond SQLite's ASCII-only NOCASE.
        let eclair = try store.createFolder(name: "Éclair")
        #expect(throws: MeetingStore.FolderError.duplicateName("Éclair")) { try store.createFolder(name: "éCLAIR") }
        try store.renameFolder(eclair.id, to: "ÉCLAIR")   // its own name in another case is fine
        try store.renameFolder(acme.id, to: " Acme Corp ")
        #expect(try store.folders().map(\.name) == ["Acme Corp", "Hiring", "ÉCLAIR"])
        #expect(throws: MeetingStore.FolderError.missingFolder) { try store.renameFolder(FolderID("gone"), to: "X") }

        let a = Meeting(title: "A", createdAt: Date(timeIntervalSince1970: 1))
        let b = Meeting(title: "B", createdAt: Date(timeIntervalSince1970: 2))
        try store.upsertMeeting(a)
        try store.upsertMeeting(b)
        try store.moveMeeting(a.id, to: hiring.id)
        #expect(try store.meeting(a.id)?.folderID == hiring.id)
        #expect(try store.meetings(in: hiring.id).map(\.id) == [a.id])
        #expect(try store.meetings(in: nil).map(\.id) == [b.id])
        #expect(throws: MeetingStore.FolderError.missingFolder) { try store.moveMeeting(b.id, to: FolderID("gone")) }
        try store.moveMeeting(a.id, to: nil)
        #expect(try store.meeting(a.id)?.folderID == nil)
        #expect(try store.meetings(in: nil).map(\.id) == [b.id, a.id])
        // Deleted meetings take no new folder and are not listed.
        try store.moveMeeting(b.id, to: hiring.id)
        try store.tombstone(b.id)
        try store.moveMeeting(b.id, to: nil)
        #expect(try store.meeting(b.id)?.folderID == hiring.id)
        #expect(try store.meetings(in: hiring.id).isEmpty)
        // Folders survive reopening.
        #expect(try MeetingStore(root: root).folders().map(\.name) == ["Acme Corp", "Hiring", "ÉCLAIR"])
    }

    @Test func staleWritersKeepTheStoredFolder() throws {
        let (store, root) = try tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try store.createFolder(name: "Acme")
        var m = Meeting(title: "Recording", createdAt: Date(), captureState: .recording, folderID: folder.id)
        try store.upsertMeeting(m)
        #expect(try store.meeting(m.id)?.folderID == folder.id, "a new row takes its folder as given (T42's default folder)")
        try store.moveMeeting(m.id, to: nil)
        m.captureState = .captured
        try store.upsertMeeting(m)   // the recorder's copy still says Acme
        #expect(try store.meeting(m.id)?.folderID == nil)
        // A new meeting naming a folder deleted meanwhile is saved unfiled rather than failing.
        try store.deleteFolder(folder.id)
        let late = Meeting(title: "Late", createdAt: Date(), folderID: folder.id)
        try store.upsertMeeting(late)
        #expect(try store.meeting(late.id)?.folderID == nil)
    }

    /// Deleting a folder unfiles its meetings and changes nothing else: every other table is byte-identical and each
    /// meeting row differs only in its folder.
    @Test func deletingAFolderKeepsItsMeetings() throws {
        let (store, root) = try tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try store.createFolder(name: "Acme")
        let other = try store.createFolder(name: "Other")
        for f in Fixtures.all {
            try store.upsertMeeting(f.meeting)
            try store.insertEpochs(f.epochs)
            try store.insertSegments(f.audioSegments)
            try store.insertEvents(f.events)
            if let t = f.transcript { _ = try store.publishTranscript(t) }
            try store.moveMeeting(f.meeting.id, to: folder.id)
        }
        let kept = Fixtures.all[0].meeting.id
        try store.moveMeeting(kept, to: other.id)
        let tables = ["capture_epochs", "audio_segments", "capture_events", "processing_jobs", "transcript_revisions", "diarization_results",
                      "user_edits", "summary_revisions", "scratchpad_revisions", "manual_notes_revisions", "search_index"]
        func dump(_ table: String) throws -> [String] {
            try store.withDB { try $0.run("SELECT * FROM \(table)").map { "\($0.sorted { $0.key < $1.key })" }.sorted() }
        }
        let before = try tables.map(dump)
        let meetingsBefore = try store.meetings()
        try store.deleteFolder(folder.id)
        #expect(try tables.map(dump) == before)
        #expect(try store.folders().map(\.name) == ["Other"])
        let after = try store.meetings()
        #expect(after.count == meetingsBefore.count)
        for (old, new) in zip(meetingsBefore, after) {
            var expected = old
            if expected.folderID == folder.id { expected.folderID = nil }
            #expect(new == expected)
        }
        #expect(try store.meeting(kept)?.folderID == other.id)
        #expect(try store.withDB { try $0.run("SELECT COUNT(*) AS n FROM meetings WHERE folder_id IS NOT NULL").first?["n"]?.int } == 1)
        try store.deleteFolder(FolderID("gone"))   // no-op
    }

    @Test func unfiledMeetingsEncodeAsBefore() throws {
        let m = Meeting(id: MeetingID("m1"), title: "Plain", createdAt: Date(timeIntervalSince1970: 0))
        #expect(!String(decoding: try ContractCoding.encode(m), as: UTF8.self).contains("folder"))
        var filed = m
        filed.folderID = FolderID("f1")
        #expect(try ContractCoding.decode(Meeting.self, from: ContractCoding.encode(filed)) == filed)
    }

    /// A v4 library (before T39) opens, migrates to v5 with every meeting unfiled, then takes folders.
    @Test func v4LibraryMigratesWithMeetingsUnfiled() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "amr-v4-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let f = Fixtures.twoSourceConversation
        do {
            let db = try SQLiteDB(path: root.appending(path: "amaranth.sqlite").path)
            for sql in Schema.migrations.prefix(4) { try db.exec(sql) }
            try db.exec("PRAGMA user_version = 4")
            try db.run("""
                INSERT INTO meetings (id, title, created_at, capture_state, selected_sources, audio, duration_ns, json)
                VALUES (?,?,?,?,?,?,?,?)
                """, [.text(f.meeting.id.rawValue), .text(f.meeting.title), .double(f.meeting.createdAt.timeIntervalSince1970),
                      .text(f.meeting.captureState.rawValue), .text(f.meeting.selectedSources.rawValue), .text(f.meeting.audio.rawValue),
                      .int(f.meeting.duration.nanoseconds), .blob(try ContractCoding.encode(f.meeting))])
        }
        let store = try MeetingStore(root: root)
        #expect(try store.withDB { try $0.run("PRAGMA user_version").first?["user_version"]?.int } == 5)
        #expect(try store.meeting(f.meeting.id) == f.meeting)
        #expect(try store.folders().isEmpty)
        #expect(try store.meetings(in: nil).map(\.id) == [f.meeting.id])
        let folder = try store.createFolder(name: "Acme")
        try store.moveMeeting(f.meeting.id, to: folder.id)
        #expect(try store.meetings(in: folder.id).map(\.id) == [f.meeting.id])
    }
}
