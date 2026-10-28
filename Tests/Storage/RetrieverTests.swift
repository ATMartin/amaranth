import Foundation
import Testing
@testable import Storage
import Domain
import DomainFixtures

/// T53: passages for “ask anything”, on the fixture conversation (“Launch checklist”: Speaker 1 on the mic, Speakers 2
/// and 3 remote; g0–g6).
@Suite("Retriever (T53)")
struct RetrieverTests {
    func fixtureStore() throws -> (MeetingStore, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "amr-retr-\(UUID())")
        let store = try MeetingStore(root: root)
        for f in Fixtures.all {
            try store.upsertMeeting(f.meeting)
            if let t = f.transcript { _ = try store.publishTranscript(t) }
            for e in f.edits { try store.appendEdit(e) }
            if let s = f.summary { _ = try store.publishSummary(s) }
        }
        return (store, root)
    }

    let launch = Fixtures.twoSourceConversation

    func rename(_ store: MeetingStore, _ speaker: String, _ name: String) throws {
        let rev = try #require(launch.transcript).id
        try store.appendEdit(UserEdit(meetingID: launch.meeting.id, baseRevisionID: rev, sequence: 100, createdAt: Date(),
                                      operation: .renameSpeaker(SpeakerID(speaker), displayName: name)))
    }

    @Test func questionTerms() {
        #expect(Retriever.terms("What did Rochelle say about the kitchens?") == ["rochelle", "kitchen"])
        #expect(Retriever.terms("When are we shipping, and who's deciding?") == ["shipp", "decid"])
        #expect(Retriever.terms("what did they say") == ["what", "did", "they", "say"], "all stop words: keep them rather than search nothing")
        #expect(Retriever.terms("\"x\" OR y* NEAR(") == ["x", "y", "near"], "no FTS syntax survives")
        #expect(Retriever.terms("  ?! ").isEmpty)
    }

    @Test func ranksTheAnsweringLineFirst() throws {
        let (store, root) = try fixtureStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let passages = try Retriever(store: store).search("When do we ship?", in: launch.meeting.id)
        let top = try #require(passages.first)
        // The decision note and the line it came from both say it; either may lead, but both are found.
        #expect(top.ref == "g3" || top.ref == "n-d1")
        #expect(passages.contains { $0.source == .transcript && $0.lines.contains { $0.segmentID?.rawValue == "g3" && $0.matched } })
        #expect(passages.contains { $0.source == .notes && $0.ref == "n-d1" })
        // ±2 lines of context around g3 (the fixture's lines merge into one window).
        let window = try #require(passages.first { $0.source == .transcript })
        let ids = window.lines.compactMap { $0.segmentID?.rawValue }
        #expect(ids.contains("g1") && ids.contains("g5"))
        let starts = window.lines.map { $0.start?.nanoseconds ?? 0 }
        #expect(starts == starts.sorted(), "in transcript order")
        #expect(try Retriever(store: store).search("zebra unicorn").isEmpty)
    }

    @Test func speakerNamesMatchAfterRename() throws {
        let (store, root) = try fixtureStore()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try Retriever(store: store).search("what did Rochelle say about notarization").first?.ref != "g2")
        try rename(store, "spk-3", "Rochelle")   // indexed at once, before reconciliation publishes a new revision
        #expect(try store.search("rochelle").contains { $0.kind == .speaker && $0.ref == "spk-3" })
        #expect(try store.search("rochelle").allSatisfy { $0.kind == .speaker }, "keyword search doesn't list every line of hers")
        let passages = try Retriever(store: store).search("what did Rochelle say about notarization")
        let top = try #require(passages.first)
        // g2 (Speakers 2 + 3, about notarization) beats g6 (Speaker 2 only, also about notarization).
        #expect(top.ref == "g2")
        #expect(top.lines.first { $0.segmentID?.rawValue == "g2" }?.speaker == "Speaker 2, Rochelle")
        #expect(top.lines.first { $0.segmentID?.rawValue == "g5" }?.speaker == "Rochelle")
    }

    @Test func evidenceResolvesToTranscriptWords() throws {
        let (store, root) = try fixtureStore()
        defer { try? FileManager.default.removeItem(at: root) }
        var checked = 0
        for q in ["ship thursday", "notarization", "release notes", "remote audio dropped", "launch checklist installer"] {
            for p in try Retriever(store: store).search(q) {
                #expect(!p.evidence.isEmpty, "\(q): \(p.ref) has evidence")
                for e in p.evidence {
                    let m = try #require(try store.meeting(p.meetingID))
                    #expect(e.revisionID == m.currentTranscriptRevisionID)
                    let t = try #require(try store.transcriptRevision(e.revisionID))
                    let seg = try #require(t.segments.first { $0.id == e.segmentID })
                    let ids = seg.words.map(\.id)
                    let a = try #require(ids.firstIndex(of: e.firstWord)), b = try #require(ids.firstIndex(of: e.lastWord))
                    #expect(a <= b)
                    checked += 1
                }
                if p.source == .transcript {
                    #expect(Set(p.evidence.map(\.segmentID)) == Set(p.lines.compactMap(\.segmentID)), "one ref per line shown")
                }
            }
        }
        #expect(checked > 10)
    }

    @Test func scopeAndPeople() throws {
        let (store, root) = try fixtureStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let all = try Retriever(store: store).search("notarization")
        #expect(Set(all.map(\.meetingID)).count > 1, "the fixtures have two copies of the launch meeting")
        #expect(try Retriever(store: store).search("notarization", in: launch.meeting.id).allSatisfy { $0.meetingID == launch.meeting.id })
        // T42: “This folder” keeps passages to the folder's meetings.
        let folder = try store.createFolder(name: "Launches")
        try store.moveMeeting(launch.meeting.id, to: folder.id)
        let inFolder = try Retriever(store: store).search("notarization", folder: folder.id)
        #expect(!inFolder.isEmpty && inFolder.allSatisfy { $0.meetingID == launch.meeting.id })
        try store.moveMeeting(launch.meeting.id, to: nil)
        #expect(try Retriever(store: store).search("notarization", folder: folder.id).isEmpty)
        try store.setPeople([Person(name: "Ana Ruiz")], for: launch.meeting.id)
        #expect(try store.search("ruiz").contains { $0.kind == .person && $0.meetingID == launch.meeting.id })
        // A person named in the question boosts that meeting's passages.
        let boosted = try Retriever(store: store).search("Ana Ruiz notarization")
        let plain = try Retriever(store: store).search("notarization")
        let score = { (ps: [Passage]) in ps.first { $0.meetingID == launch.meeting.id }?.score ?? 0 }
        #expect(score(boosted) > score(plain))
        try store.setPeople([], for: launch.meeting.id)
        #expect(try store.search("ruiz").isEmpty)
        #expect(Retriever(store: store).k == 12)
        #expect(try Retriever(store: store, k: 2).search("the audio notes ship").count == 2)
    }

    /// A library from before T53 (schema v3, old index layout) is migrated and its index rebuilt once on open.
    @Test func v3LibraryIsReindexed() throws {
        let (store, root) = try fixtureStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.withDB { db in
            try db.exec("""
                DROP TABLE search_index;
                CREATE VIRTUAL TABLE search_index USING fts5(meeting_id UNINDEXED, kind UNINDEXED, ref UNINDEXED, start_ns UNINDEXED, text,
                    tokenize='unicode61 remove_diacritics 2');
                DROP INDEX meetings_by_folder;
                ALTER TABLE meetings DROP COLUMN folder_id;
                DROP TABLE folders;
                PRAGMA user_version = 3;
                """)
        }
        let reopened = try MeetingStore(root: root)
        #expect(try reopened.searchRowCount(launch.meeting.id) > 7)
        let p = try #require(try Retriever(store: reopened).search("notarization").first { $0.source == .transcript })
        #expect(!p.evidence.isEmpty && p.lines.contains { $0.speaker != nil })
        #expect(try reopened.withDB { try $0.run("PRAGMA user_version").first?["user_version"]?.int } == Int64(Schema.migrations.count))
    }
}

@Suite("Retriever across meetings (T55)")
struct RetrieverSpreadTests {
    func p(_ m: String, _ ref: String, _ score: Double) -> Passage {
        Passage(meetingID: MeetingID(m), meetingTitle: m, meetingDate: Date(), source: .transcript, ref: ref, lines: [], evidence: [], score: score)
    }

    @Test func strongMeetingsShareTheSlots() {
        let ranked = [p("a", "1", 10), p("a", "2", 9.5), p("a", "3", 9), p("b", "1", 6), p("a", "4", 5), p("b", "2", 4), p("c", "1", 2)]
        let out = Retriever.spread(ranked, k: 4)
        #expect(out.map { "\($0.meetingID.rawValue)\($0.ref)" } == ["a1", "b1", "a2", "b2"], "a and b alternate; c (20% of the top) waits")
        #expect(Retriever.spread(ranked, k: 7).map(\.meetingID.rawValue).last == "c", "weak meetings fill what's left")
        #expect(Retriever.spread([], k: 4).isEmpty)
    }
}

@Suite("Retriever windows (T53/T54)")
struct RetrieverWindowTests {
    /// Thirty consecutive lines all mention the kitchen: windows must not chain into one huge passage (each spans at most
    /// `maxSpan` matched rows plus ±2 lines of context) and no line may appear in two passages.
    @Test func windowsStayShortAndNeverShareLines() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "amr-win-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let m = MeetingID("win"), rev = RevisionID("win-r1")
        var segs: [TranscriptSegment] = []
        for i in 0..<30 {
            let t0 = Double(i) * 5
            var words: [Word] = []
            for (j, w) in ["the", "kitchen", "plan", "step", "\(i)"].enumerated() {
                let a = t0 + Double(j) * 0.5
                words.append(Word(id: WordID("w\(i)-\(j)"), text: w, interval: .seconds(a, a + 0.4), source: .microphone))
            }
            segs.append(TranscriptSegment(id: TranscriptSegmentID("w\(i)"), source: .microphone, interval: .seconds(t0, t0 + 4), words: words, speaker: .unknown))
        }
        try store.upsertMeeting(Meeting(id: m, title: "Renovation", createdAt: Date(), captureState: .captured, duration: .seconds(150)))
        _ = try store.publishTranscript(TranscriptRevision(id: rev, meetingID: m, kind: .final, stage: .asr, createdAt: Date(),
                                                           producer: ProducerInfo(component: "t", configHash: "t"), segments: segs, coverage: []))
        let r = Retriever(store: store, k: 30)
        let passages = try r.search("kitchen plan", in: m)
        #expect(passages.count >= 3)
        var seen = Set<String>()
        for p in passages {
            let ids = p.lines.compactMap { $0.segmentID?.rawValue }
            #expect(ids.count <= r.maxSpan + 1 + 2 * r.window, "\(ids.count) lines")
            for id in ids { #expect(seen.insert(id).inserted, "\(id) appears twice") }
        }
    }
}
