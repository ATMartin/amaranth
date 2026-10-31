import Foundation
import Testing
@testable import Storage
import Domain

/// T89: a v5 library (generated notes, "Your notes", private scratchpads) opens as v6 with one notes document per meeting
/// (spec 0008 §8). Scratchpads never used for notes are deleted (user decision 2026-10-31).
@Suite("Notes document storage and v5 → v6 migration")
struct NotesDocumentMigrationTests {
    let tr = RevisionID("tr")
    var spoken: EvidenceRef { .transcript(TranscriptEvidence(revisionID: tr, segmentID: .init("s"), firstWord: .init("a"), lastWord: .init("b"))) }

    func summary(_ m: MeetingID, pad: RevisionID? = nil) -> SummaryRevision {
        var items = [SummaryItem(kind: .decision, text: "Ship the build \(m.rawValue)", evidence: [spoken])]
        if let pad { items.append(SummaryItem(kind: .openQuestion, text: "Ask about hiring", evidence: [spoken, .personalNote(ScratchpadEvidence(revisionID: pad, start: 0, end: 4))])) }
        return SummaryRevision(id: RevisionID("sum-\(m.rawValue)"), meetingID: m, transcriptRevisionID: tr, editSequence: 0, createdAt: Date(timeIntervalSince1970: 10),
                               producer: ProducerInfo(component: "t", configHash: "t"), promptVersion: "notes-v3",
                               content: SummaryContent(decisions: items.filter { $0.kind == .decision }, openQuestions: items.filter { $0.kind == .openQuestion },
                                                       limitations: pad == nil ? [] : [SummaryItem(kind: .limitation, text: "These notes also used your personal notes, which were not spoken in the meeting.", evidence: [])]),
                               validation: SummaryValidationReport(status: .valid), scratchpadRevisionID: pad, influencedByPersonalNotes: pad != nil)
    }

    /// Builds a v5 database by hand (as the v5 app wrote it) and returns the meetings by case name.
    func makeV5Library(_ root: URL) throws -> [String: MeetingID] {
        let db = try SQLiteDB(path: root.appending(path: "amaranth.sqlite").path)
        for sql in Schema.migrations.prefix(5) { try db.exec(sql) }
        try db.exec("PRAGMA user_version = 5")
        var ids: [String: MeetingID] = [:]
        func meeting(_ name: String, summary s: SummaryRevision? = nil, deleted: Bool = false) throws -> MeetingID {
            let id = MeetingID(name)
            var m = Meeting(id: id, title: "Meeting \(name)", createdAt: Date(timeIntervalSince1970: 0), captureState: .captured)
            m.currentSummaryRevisionID = s?.id
            if deleted { m.deletedAt = Date() }
            try db.run("""
                INSERT INTO meetings (id, title, created_at, capture_state, selected_sources, audio, duration_ns, current_summary_revision, deleted_at, json)
                VALUES (?,?,?,?,?,?,?,?,?,?)
                """, [.text(name), .text(m.title), .double(0), .text(m.captureState.rawValue), .text(m.selectedSources.rawValue), .text(m.audio.rawValue),
                      .int(0), s.map { .text($0.id.rawValue) } ?? .null, deleted ? .double(1) : .null, .blob(try ContractCoding.encode(m))])
            if let s {
                try db.run("INSERT INTO summary_revisions (id, meeting_id, transcript_revision, created_at, json) VALUES (?,?,?,?,?)",
                           [.text(s.id.rawValue), .text(name), .text(tr.rawValue), .double(10), .blob(try ContractCoding.encode(s))])
            }
            ids[name] = id
            return id
        }
        func manual(_ id: MeetingID, _ text: String) throws {
            let n = ManualNotesRevision(meetingID: id, basedOnSummaryRevisionID: nil, markdown: text, createdAt: Date(timeIntervalSince1970: 20))
            try db.run("INSERT INTO manual_notes_revisions (id, meeting_id, created_at, json) VALUES (?,?,?,?)",
                       [.text(n.id.rawValue), .text(id.rawValue), .double(20), .blob(try ContractCoding.encode(n))])
        }
        func pad(_ id: MeetingID, _ text: String, include: Bool, rev: RevisionID = RevisionID(), at: Double = 30) throws {
            let p = ScratchpadRevision(id: rev, meetingID: id, text: text, includeInSummary: include, createdAt: Date(timeIntervalSince1970: at))
            try db.run("INSERT INTO scratchpad_revisions (id, meeting_id, created_at, json) VALUES (?,?,?,?)",
                       [.text(p.id.rawValue), .text(id.rawValue), .double(at), .blob(try ContractCoding.encode(p))])
        }
        _ = try meeting("summaryOnly", summary: summary(MeetingID("summaryOnly")))
        try manual(try meeting("withYourNotes", summary: summary(MeetingID("withYourNotes"))), "# Follow-up\n- call the vendor tangerinewalrus\nbudget is tight")
        let inc = try meeting("includedPad", summary: summary(MeetingID("includedPad"), pad: RevisionID("pad-inc")))
        try pad(inc, "hiring plan for marmalade team", include: true, rev: RevisionID("pad-inc"))
        try pad(try meeting("excludedPad", summary: summary(MeetingID("excludedPad"))), "PRIVATE secret quokkapudding", include: false)
        // Was used for notes once (the current notes cite it), then switched off: the cited text is what was used.
        let off = try meeting("switchedOff", summary: summary(MeetingID("switchedOff"), pad: RevisionID("pad-off-1")))
        try pad(off, "used lemonbadger line", include: true, rev: RevisionID("pad-off-1"), at: 30)
        try pad(off, "used lemonbadger line plus later private zebracrumpet", include: false, at: 40)
        try manual(try meeting("notesNoSummary"), "only my words")
        _ = try meeting("empty")
        try pad(try meeting("gone", deleted: true), "", include: false)
        return ids
    }

    @Test func v5LibraryMigratesEveryCombination() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "amr-v5-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = try makeV5Library(root)
        let store = try MeetingStore(root: root)
        #expect(try store.withDB { try $0.run("PRAGMA user_version").first?["user_version"]?.int } == 6)
        func doc(_ name: String) throws -> NotesDocumentRevision {
            let revs = try store.notesDocumentRevisions(ids[name]!)
            #expect(revs.count == 1, "exactly one document for \(name)")
            return try #require(revs.first)
        }
        let a = try doc("summaryOnly")
        #expect(a.origin == .migrated && a.basedOnSummaryRevisionID == RevisionID("sum-summaryOnly"))
        #expect(a.blocks.map(\.text) == ["Decisions", "Ship the build summaryOnly"])
        #expect(a.blocks[1].evidence == [spoken] && !a.blocks[1].isUser)

        let b = try doc("withYourNotes")
        #expect(b.blocks.map(\.text) == ["Decisions", "Ship the build withYourNotes", "Also noted", "Follow-up", "call the vendor tangerinewalrus", "budget is tight"])
        #expect(b.userBlocks.map(\.kind) == [.heading, .bullet, .paragraph] && b.userBlocks.allSatisfy { $0.author == .user(typedAt: nil) })

        let c = try doc("includedPad")
        #expect(c.blocks.allSatisfy { $0.evidence.allSatisfy(\.isSpoken) }, "scratchpad citations dropped")
        #expect(!c.blocks.contains { $0.text.contains("personal notes") }, "the old 'used your personal notes' limitation goes")
        #expect(c.userBlocks.map(\.text) == ["hiring plan for marmalade team"])

        let d = try doc("excludedPad")
        #expect(d.userBlocks.isEmpty)
        #expect(try store.latestScratchpad(ids["excludedPad"]!) == nil, "never-included scratchpad deleted")
        #expect(try store.latestScratchpad(ids["includedPad"]!) != nil, "an included one stays readable")

        let e = try doc("switchedOff")
        #expect(e.userBlocks.map(\.text) == ["used lemonbadger line"], "the revision generation used, not the later private text")

        #expect(try doc("notesNoSummary").blocks.map(\.text) == ["only my words"])
        #expect(try doc("empty").blocks.isEmpty)
        #expect(try store.notesDocumentRevisions(ids["gone"]!).isEmpty, "deleted meetings get nothing")

        // Search: the document is the notes; user lines are found as notes, never-included scratchpad text nowhere.
        #expect(try store.search("tangerinewalrus").map(\.kind) == [.notes])
        #expect(try store.search("marmalade").map(\.kind) == [.notes])
        #expect(try store.search("quokkapudding").isEmpty && store.search("zebracrumpet").isEmpty)
        // Deleted scratchpad text is gone from the database bytes too (secure_delete + WAL checkpoint after migrating).
        for name in ["amaranth.sqlite", "amaranth.sqlite-wal"] {
            let bytes = (try? Data(contentsOf: root.appending(path: name))) ?? Data()
            for secret in ["quokkapudding", "zebracrumpet"] { #expect(bytes.range(of: Data(secret.utf8)) == nil, "\(secret) in \(name)") }
        }
        // Reopening does not migrate again.
        let reopened = try MeetingStore(root: root)
        #expect(try reopened.notesDocumentRevisions(ids["withYourNotes"]!).count == 1)
    }

    @Test func savesAreNewRevisionsNewestFirstAndDeletedMeetingsRefuse() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "amr-notes-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let m = MeetingID()
        try store.upsertMeeting(Meeting(id: m, title: "T", createdAt: Date(), captureState: .captured))
        #expect(try store.currentNotesDocument(m) == nil)
        let one = NotesDocumentRevision(meetingID: m, createdAt: Date(timeIntervalSince1970: 1), origin: .edited,
                                        blocks: NotesComposer.userBlocks(fromText: "first draft"))
        var two = one
        two.id = RevisionID(); two.createdAt = Date(timeIntervalSince1970: 2); two.blocks[0] = two.blocks[0].editing(text: "second draft")
        #expect(try store.saveNotesDocument(one) && store.saveNotesDocument(two))
        #expect(try store.notesDocumentRevisions(m).map(\.id) == [two.id, one.id])
        #expect(try store.currentNotesDocument(m) == two)
        #expect(try store.search("second").map(\.kind) == [.notes] && store.search("first").isEmpty, "only the current revision is indexed")
        // Publishing generated notes composes a document that keeps the user's lines.
        let s = SummaryRevision(meetingID: m, transcriptRevisionID: tr, editSequence: 0, createdAt: Date(), producer: ProducerInfo(component: "t", configHash: "t"),
                                promptVersion: "notes-v3", content: SummaryContent(overview: [SummaryItem(kind: .overview, text: "Overview", evidence: [spoken])]),
                                validation: SummaryValidationReport(status: .valid))
        #expect(try store.publishSummary(s))
        let composed = try #require(try store.currentNotesDocument(m))
        #expect(composed.origin == .generated && composed.basedOnSummaryRevisionID == s.id)
        #expect(composed.userBlocks == two.userBlocks)
        var m2 = try #require(try store.meeting(m)); m2.deletedAt = Date(); try store.upsertMeeting(m2)
        var three = two; three.id = RevisionID()
        #expect(try store.saveNotesDocument(three) == false)
        #expect(try store.saveNotesDocument(NotesDocumentRevision(meetingID: MeetingID("nope"), createdAt: Date(), origin: .edited, blocks: [])) == false)
    }
}
