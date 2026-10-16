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
}
