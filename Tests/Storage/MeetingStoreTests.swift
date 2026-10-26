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
}

