import Foundation
import Testing
@testable import Storage
import Domain
@testable import MeetingAccess

/// Regression tests for the Milestone S validator's findings (verdict v1): M1 stable search pages, M2 the 64 KiB
/// ceiling for every operation, S1 unfinished exports from another library, S2 inert Markdown in notes apps, S4 cursors
/// bound to scope, N5/N7 link rules.
@Suite("Milestone S validator fixes")
struct ValidatorFixTests {
    static func size<T: Encodable>(_ v: T) throws -> Int { try ExternalCoding.encoder(pretty: false).encode(v).count }

    /// M1: more than 200 matching rows (the old candidate pool); paging to the end gives every passage once, in rank order.
    @Test func searchPagesAreSlicesOfOneRanking() throws {
        let lib = try RetrievalLibrary()
        for m in 0..<12 {
            try lib.meeting("Standup \(m)", lines: (0..<60).map { i in i % 3 == 0 ? "the roadmap budget item \(m)-\(i) needs review" : "filler talk \(i) about lunch plans" })
        }
        var seen: [String] = []
        var ranks: [Int] = []
        var cursor: String?
        repeat {
            let page = try lib.reader.searchMeetings(SearchMeetingsRequest(query: "roadmap budget", cursor: cursor, limit: 20))
            seen += page.passages.map { "\($0.meetingID)|\($0.ref)|\($0.source)" }
            ranks += page.passages.map(\.rank)
            cursor = page.nextCursor
        } while cursor != nil
        #expect(seen.count == Set(seen).count, "a passage appeared on two pages")
        #expect(ranks == Array(1...ranks.count) && seen.count >= 60)
        let whole = try lib.reader.searchMeetings(SearchMeetingsRequest(query: "roadmap budget", limit: 20)).passages.map { "\($0.meetingID)|\($0.ref)|\($0.source)" }
        #expect(Array(seen.prefix(20)) == whole)
    }

    /// M2: hostile sizes never push a response past 64 KiB, and paging still moves in big steps.
    @Test func everyOperationStaysWithinTheBudget() throws {
        let lib = try RetrievalLibrary()
        let longTitle = String(repeating: "Ü", count: 100_000)
        let people = (0..<3_000).map { "Person \($0) " + String(repeating: "é", count: 300) }
        var ids: [MeetingID] = []
        for i in 0..<50 { ids.append(try lib.meeting(longTitle + "\(i)", lines: ["zebracorn line \(i)"], people: Array(people.prefix(20)))) }
        let big = try lib.meeting(longTitle, lines: (0..<400).map { "zebracorn transcript line \($0)" }, people: people,
                                  notes: [String(repeating: "quokkanote ", count: 14_000)])
        let budget = AccessLimits.maxResponseBytes
        let list = try lib.reader.listMeetings(ListMeetingsRequest(limit: 50))
        #expect(try Self.size(list) <= budget && list.nextCursor != nil && list.meetings.allSatisfy { $0.shortened == true })
        #expect(list.limitations.contains(ProjectionCaps.note))
        var cursor: String? = nil, listed = 0
        repeat {
            let p = try lib.reader.listMeetings(ListMeetingsRequest(cursor: cursor, limit: 50))
            #expect(try Self.size(p) <= budget)
            listed += p.meetings.count; cursor = p.nextCursor
        } while cursor != nil
        #expect(listed == 51)
        let meta = try lib.reader.getMeeting(GetMeetingRequest(meetingID: big.rawValue, section: .metadata))
        #expect(try Self.size(meta) <= budget && meta.meeting.shortened == true && meta.meeting.people.count == ProjectionCaps.listItems)
        var pages = 0
        cursor = nil
        repeat {
            let t = try lib.reader.getMeeting(GetMeetingRequest(meetingID: big.rawValue, section: .transcript, cursor: cursor))
            #expect(try Self.size(t) <= budget)
            pages += 1; cursor = t.nextCursor
        } while cursor != nil && pages < 50
        #expect(pages < 10, "transcript paging must not crawl")
        let notes = try lib.reader.getMeeting(GetMeetingRequest(meetingID: big.rawValue, section: .notes))
        #expect(try Self.size(notes) <= budget)
        let search = try lib.reader.searchMeetings(SearchMeetingsRequest(query: "quokkanote zebracorn", limit: 20))
        #expect(try Self.size(search) <= budget && !search.passages.isEmpty)
        let shortened = search.passages.flatMap(\.lines).filter { $0.shortened == true }
        #expect(!shortened.isEmpty && shortened.allSatisfy { $0.text.count <= ProjectionCaps.searchLine })
        #expect(search.limitations.contains { $0.contains("shortened") })
    }

    /// S1: a folder holding an unfinished export of library A is refused for library B.
    @Test func unfinishedExportOfAnotherLibraryIsRefused() throws {
        let a = try RetrievalLibrary(), b = try RetrievalLibrary()
        let ida = try (0..<3).map { try a.meeting("A\($0)", lines: ["a"]) }
        let d = BulkExportTests.dest()
        let counter = BulkExportTests.Counter()
        #expect(BulkExport.run(a.reader, meetings: ida, content: .notes, destination: d, isCancelled: { counter.next() > 1 }).status == .cancelled)
        let r = BulkExport.run(b.reader, meetings: [try b.meeting("B", lines: ["b"])], content: .notes, destination: d)
        #expect(r.status == .failed && r.errors[0].message.contains("unfinished export from another"))
        // v2 N-a: without its marker, an unfinished run can't be attributed: refused for everyone.
        let marker = d.appending(path: "amaranth/.export-in-progress.json")
        let saved = try Data(contentsOf: marker)
        try FileManager.default.removeItem(at: marker)
        #expect(BulkExport.run(b.reader, meetings: [try b.meeting("B2", lines: ["b"])], content: .notes, destination: d).errors.first?.message.contains("can't identify") == true)
        try saved.write(to: marker)
        #expect(BulkExport.run(a.reader, meetings: ida, content: .notes, destination: d).status == .complete)   // A can finish it
        let manifest = try ExternalCoding.decoder().decode(BulkExport.Manifest.self, from: Data(contentsOf: d.appending(path: "amaranth/manifest.json")))
        #expect(manifest.otherFiles?.map(\.path) == ["README.md"])   // N3: README hash recorded
    }

    /// S2: autolinks, Obsidian comments/highlights/math/block IDs stay inert text in the export body.
    @Test func notesAppSyntaxStaysText() throws {
        let lib = try RetrievalLibrary()
        let m = try lib.meeting("Links https://evil.example/x", lines: ["visit www.evil.test or mail me@evil.example %%hidden%% ==hl== $$x$$ ^block"])
        let d = BulkExportTests.dest()
        _ = BulkExport.run(lib.reader, meetings: [m], content: .notesAndTranscript, destination: d)
        let md = BulkExportTests.read(d.appending(path: "amaranth/\(m.rawValue)/meeting.md"))
        let body = md.components(separatedBy: "\n---\n").dropFirst().joined()
        for raw in ["https://evil", "www.evil", "me@evil", "%%hidden%%", "==hl==", "$$x$$", " ^block"] { #expect(!body.contains(raw), "\(raw) left live") }
        #expect(md.contains("title: \"Links https://evil.example/x\""))   // front matter keeps the exact text
    }

    /// S4: a cursor made under one scope can't continue under another.
    @Test func cursorsAreBoundToScope() throws {
        let lib = try RetrievalLibrary()
        let ids = try (0..<4).map { try lib.meeting("M\($0)", lines: ["walrus"]) }
        let page = try lib.reader.listMeetings(ListMeetingsRequest(limit: 1))
        #expect(throws: AccessError.invalidRequest("cursor belongs to another request")) {
            try lib.reader.listMeetings(ListMeetingsRequest(cursor: page.nextCursor, limit: 1), scope: .meetings(Set(ids)))
        }
    }

    /// N7: odd IDs never produce a link that could break out of Markdown.
    @Test func oddIDsMakeNoLinks() {
        #expect(SourceURL(meetingID: MeetingID("not-a-uuid)")).string.isEmpty)
        #expect(SourceURL(meetingID: MeetingID(UUID().uuidString.lowercased()), source: .notes, ref: "a)b", revision: "r").string.isEmpty)
        #expect(MeetingFiles.link("00:01", "") == "00:01")
    }
}
