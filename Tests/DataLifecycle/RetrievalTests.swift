import Foundation
import Testing
@testable import Storage
import Domain
import MeetingAccess

/// A small isolated library for T98: meetings with plain transcript lines, people, folders and start times.
struct RetrievalLibrary {
    let root: URL
    let store: MeetingStore
    let reader: MeetingReader

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "amr-retrieval-\(UUID())")
        store = try MeetingStore(root: root)
        reader = MeetingReader(store: store)
    }

    @discardableResult
    func meeting(_ title: String, lines: [String], people: [String] = [], folder: FolderID? = nil, start: Date = Date(timeIntervalSince1970: 1_800_000_000),
                 notes: [String] = []) throws -> MeetingID {
        let m = MeetingID()
        try store.upsertMeeting(Meeting(id: m, title: title, createdAt: start,
                                        clock: SessionClock(utcOrigin: start, timeZoneIdentifier: "UTC", hostTimeOriginNanos: 0),
                                        captureState: .captured, duration: .seconds(Double(lines.count) * 5), folderID: folder))
        if !people.isEmpty { try store.setPeople(people.map { Person(name: $0) }, for: m) }
        if !lines.isEmpty {
            let spk = SpeakerID("spk")
            let segs = lines.enumerated().map { i, text in
                let words = text.split(separator: " ").enumerated().map { j, w in
                    Word(id: WordID("\(i)-\(j)"), text: String(w), interval: .seconds(Double(i) * 5 + Double(j) * 0.2, Double(i) * 5 + Double(j) * 0.2 + 0.15), source: .systemOutput, speaker: .speaker(spk))
                }
                return TranscriptSegment(id: TranscriptSegmentID("seg\(i)"), source: .systemOutput,
                                         interval: SessionInterval(unchecked: words.first!.interval.start, words.last!.interval.end), words: words, speaker: .speaker(spk))
            }
            try store.publishTranscript(TranscriptRevision(meetingID: m, kind: .final, stage: .attributed, createdAt: start, producer: ProducerInfo(component: "t", configHash: "t"),
                                                           segments: segs, coverage: [], speakers: [Speaker(id: spk, label: "Speaker 1")]))
        }
        if !notes.isEmpty {
            try store.saveNotesDocument(NotesDocumentRevision(meetingID: m, createdAt: start, origin: .edited, blocks: notes.flatMap { NotesComposer.userBlocks(fromText: $0) }))
        }
        return m
    }
}

@Suite("External retrieval (T98)")
struct RetrievalTests {
    let day = 86_400.0, t0 = 1_800_000_000.0

    @Test func filtersIntersectAndParticipantIsNotSpeaker() throws {
        let lib = try RetrievalLibrary()
        let clients = try lib.store.createFolder(name: "Clients")
        let a = try lib.meeting("Acme kickoff", lines: ["the gizmo budget is approved"], people: ["Ana Lopez", "Ben"], folder: clients.id, start: Date(timeIntervalSince1970: t0))
        let b = try lib.meeting("Acme retro", lines: ["gizmo budget slipped again"], people: ["Ben"], folder: clients.id, start: Date(timeIntervalSince1970: t0 + day))
        let c = try lib.meeting("Internal planning", lines: ["gizmo budget for next year"], people: ["Ána"], start: Date(timeIntervalSince1970: t0 + 2 * day))
        func list(_ f: MeetingFilter) throws -> [String] { try lib.reader.listMeetings(ListMeetingsRequest(filter: f)).meetings.map(\.meetingID) }
        #expect(try list(MeetingFilter()) == [c, b, a].map(\.rawValue))   // newest first
        #expect(try list(MeetingFilter(folderID: clients.id.rawValue)) == [b, a].map(\.rawValue))
        #expect(try list(MeetingFilter(participant: "ana")) == [c, a].map(\.rawValue))   // first name, case/accent-insensitive
        #expect(try list(MeetingFilter(participant: "Ana Lopez")) == [a.rawValue])
        #expect(try list(MeetingFilter(title: "acme")) == [b, a].map(\.rawValue))
        // Inclusive start, exclusive end.
        #expect(try list(MeetingFilter(startFrom: Date(timeIntervalSince1970: t0 + day), startBefore: Date(timeIntervalSince1970: t0 + 2 * day))) == [b.rawValue])
        // Search: every filter applies before ranking, and meeting IDs intersect them.
        func search(_ ids: [MeetingID]? = nil, _ f: MeetingFilter = MeetingFilter()) throws -> Set<String> {
            Set(try lib.reader.searchMeetings(SearchMeetingsRequest(query: "gizmo budget", meetingIDs: ids?.map(\.rawValue), filter: f)).passages.map(\.meetingID))
        }
        #expect(try search() == Set([a, b, c].map(\.rawValue)))
        #expect(try search(nil, MeetingFilter(folderID: clients.id.rawValue, participant: "Ben")) == Set([a, b].map(\.rawValue)))
        #expect(try search([a, c], MeetingFilter(folderID: clients.id.rawValue)) == [a.rawValue])
        #expect(try search([c], MeetingFilter(folderID: clients.id.rawValue)).isEmpty)
        let r = try lib.reader.searchMeetings(SearchMeetingsRequest(query: "budget", filter: MeetingFilter(participant: "Ben")))
        #expect(r.limitations.contains { $0.contains("does not mean that person said") })
    }

    @Test func scopeHidesMeetingsEverywhereIncludingGuessedIDsAndContextWindows() throws {
        let lib = try RetrievalLibrary()
        // A's last lines and B's first lines are adjacent in the index: a window at A's end must not take B's lines.
        let a = try lib.meeting("Alpha", lines: ["filler one", "filler two", "filler three", "the zephyr contract is signed"])
        let b = try lib.meeting("Bravo", lines: ["SECRETBRAVO zephyr details", "SECRETBRAVO more", "SECRETBRAVO again"])
        let scope = AccessScope.meetings([a])
        let r = try lib.reader.searchMeetings(SearchMeetingsRequest(query: "zephyr"), scope: scope)
        #expect(r.passages.map(\.meetingID) == [a.rawValue])
        #expect(!r.passages.flatMap(\.lines).contains { $0.text.contains("SECRETBRAVO") })
        #expect(try lib.reader.searchMeetings(SearchMeetingsRequest(query: "zephyr", meetingIDs: [b.rawValue]), scope: scope).passages.isEmpty)
        #expect(throws: AccessError.unavailable) { try lib.reader.getMeeting(GetMeetingRequest(meetingID: b.rawValue, section: .transcript), scope: scope) }
        #expect(try lib.reader.listMeetings(ListMeetingsRequest(), scope: scope).meetings.map(\.meetingID) == [a.rawValue])
        // Unrestricted, B is found: the scope did the hiding.
        #expect(Set(try lib.reader.searchMeetings(SearchMeetingsRequest(query: "zephyr")).passages.map(\.meetingID)) == Set([a, b].map(\.rawValue)))
        // Folder scope follows moves.
        let f = try lib.store.createFolder(name: "Shared")
        #expect(try lib.reader.listMeetings(ListMeetingsRequest(), scope: .folders([f.id])).meetings.isEmpty)
        try lib.store.moveMeeting(b, to: f.id)
        #expect(try lib.reader.listMeetings(ListMeetingsRequest(), scope: .folders([f.id])).meetings.map(\.meetingID) == [b.rawValue])
        // Deleted meetings vanish.
        try lib.store.tombstone(a)
        #expect(throws: AccessError.unavailable) { try lib.reader.getMeeting(GetMeetingRequest(meetingID: a.rawValue, section: .metadata)) }
        #expect(!(try lib.reader.searchMeetings(SearchMeetingsRequest(query: "zephyr")).passages.contains { $0.meetingID == a.rawValue }))
    }

    @Test func cursorsPageStablyAndRestartWhenContentChanges() throws {
        let lib = try RetrievalLibrary()
        var ids: [MeetingID] = []
        for i in 0..<5 { ids.append(try lib.meeting("Standup \(i)", lines: ["the walrus report"], start: Date(timeIntervalSince1970: t0))) }   // tied starts
        var seen: [String] = []
        var cursor: String?
        repeat {
            let page = try lib.reader.listMeetings(ListMeetingsRequest(cursor: cursor, limit: 2))
            seen += page.meetings.map(\.meetingID); cursor = page.nextCursor
        } while cursor != nil
        #expect(seen == ids.map(\.rawValue).sorted())   // ties ordered by ID, no repeats, nothing missed
        // Identical passages in five meetings rank in a stable order and page without duplicates.
        let all = try lib.reader.searchMeetings(SearchMeetingsRequest(query: "walrus", limit: 20)).passages.map(\.meetingID)
        #expect(all.count == 5 && Set(all).count == 5)
        #expect(try lib.reader.searchMeetings(SearchMeetingsRequest(query: "walrus", limit: 20)).passages.map(\.meetingID) == all)
        let p1 = try lib.reader.searchMeetings(SearchMeetingsRequest(query: "walrus", limit: 2))
        let p2 = try lib.reader.searchMeetings(SearchMeetingsRequest(query: "walrus", cursor: p1.nextCursor, limit: 2))
        #expect(p1.passages.map(\.meetingID) + p2.passages.map(\.meetingID) == Array(all.prefix(4)))
        #expect(p2.passages.map(\.rank) == [3, 4])
        // A cursor from another query or operation is refused; a change to the library asks for a restart.
        #expect(throws: AccessError.invalidRequest("cursor belongs to another request")) {
            try lib.reader.searchMeetings(SearchMeetingsRequest(query: "report", cursor: p1.nextCursor, limit: 2))
        }
        #expect(throws: AccessError.invalidRequest("cursor")) { try lib.reader.listMeetings(ListMeetingsRequest(cursor: "not a cursor!")) }
        #expect(throws: AccessError.invalidRequest("cursor")) { try lib.reader.listMeetings(ListMeetingsRequest(cursor: "eyJ2IjoxfQ")) }
        let l1 = try lib.reader.listMeetings(ListMeetingsRequest(limit: 2))
        try lib.store.setPeople([Person(name: "Zed")], for: ids[0])
        #expect(throws: AccessError.restartRequired) { try lib.reader.listMeetings(ListMeetingsRequest(cursor: l1.nextCursor, limit: 2)) }
        #expect(throws: AccessError.restartRequired) { try lib.reader.searchMeetings(SearchMeetingsRequest(query: "walrus", cursor: p1.nextCursor, limit: 2)) }
    }

    @Test func getMeetingPagesOversizedRecordsInFragmentsWithinTheBudget() throws {
        let lib = try RetrievalLibrary()
        let huge = (0..<30_000).map { "word\($0)" }.joined(separator: " ")   // ~260 KB in one notes line
        let many = (0..<3_000).map { "line \($0) about the quarterly numbers and the plan" }
        let m = try lib.meeting("Big", lines: many, notes: ["short first line", huge, "short last line"])
        // Notes: three items, the middle one in parts that reassemble exactly.
        var texts: [Int: String] = [:]
        var cursor: String?
        var pages = 0, next = 0
        repeat {
            let r = try lib.reader.getMeeting(GetMeetingRequest(meetingID: m.rawValue, section: .notes, cursor: cursor))
            #expect(try ExternalCoding.encoder(pretty: false).encode(r).count <= AccessLimits.maxResponseBytes)
            var items = r.notes ?? []
            if let f = r.fragment {   // the part is always the page's first item
                texts[f.item, default: ""] += items.removeFirst().text
                next = f.item + (f.complete ? 1 : 0)
            }
            for n in items { texts[next] = n.text; next += 1 }
            cursor = r.nextCursor; pages += 1
        } while cursor != nil && pages < 50
        #expect(texts[0] == "short first line" && texts[1] == huge && texts[2] == "short last line" && pages >= 5)
        // Transcript: several pages, every line once, each response within budget; a time range narrows it.
        var lines: [String] = []
        cursor = nil
        repeat {
            let r = try lib.reader.getMeeting(GetMeetingRequest(meetingID: m.rawValue, section: .transcript, cursor: cursor))
            #expect(try ExternalCoding.encoder(pretty: false).encode(r).count <= AccessLimits.maxResponseBytes)
            lines += (r.transcript ?? []).map(\.text); cursor = r.nextCursor
        } while cursor != nil
        #expect(lines == many)
        let ranged = try lib.reader.getMeeting(GetMeetingRequest(meetingID: m.rawValue, section: .transcript, startNs: 10_000_000_000, endNs: 20_000_000_000))
        #expect(ranged.transcript?.map(\.text) == ["line 2 about the quarterly numbers and the plan", "line 3 about the quarterly numbers and the plan"])
        // A stale cursor (the meeting changed) restarts; a wrong fingerprint is `changed`.
        let first = try lib.reader.getMeeting(GetMeetingRequest(meetingID: m.rawValue, section: .transcript))
        var meeting = try #require(try lib.store.meeting(m)); meeting.title = "Big (renamed)"; try lib.store.upsertMeeting(meeting)
        #expect(throws: AccessError.restartRequired) { try lib.reader.getMeeting(GetMeetingRequest(meetingID: m.rawValue, section: .transcript, cursor: first.nextCursor)) }
        let now = try lib.reader.getMeeting(GetMeetingRequest(meetingID: m.rawValue, section: .metadata)).meeting.fingerprint
        #expect(throws: AccessError.changed(currentFingerprint: now)) {
            try lib.reader.getMeeting(GetMeetingRequest(meetingID: m.rawValue, section: .metadata, expectedFingerprint: first.meeting.fingerprint))
        }
        #expect(try lib.reader.getMeeting(GetMeetingRequest(meetingID: m.rawValue, section: .metadata, expectedFingerprint: now)).meeting.transcriptLineCount == 3_000)
    }

    @Test func inputsAreBoundedAndMaliciousQueriesStayText() throws {
        let lib = try RetrievalLibrary()
        let m = try lib.meeting("Ops", lines: ["deploy the canary tonight", "rollback plan is ready"])
        let r = lib.reader
        #expect(throws: AccessError.badQuery("empty query: use list_meetings to browse")) { try r.searchMeetings(SearchMeetingsRequest(query: "   ")) }
        #expect(throws: AccessError.badQuery("no searchable words in the query")) { try r.searchMeetings(SearchMeetingsRequest(query: "*** ()\"")) }
        #expect(throws: AccessError.invalidRequest("query longer than 2000 characters")) { try r.searchMeetings(SearchMeetingsRequest(query: String(repeating: "a", count: 2001))) }
        #expect(throws: AccessError.invalidRequest("more than 50 meetingIDs")) { try r.searchMeetings(SearchMeetingsRequest(query: "canary", meetingIDs: (0..<51).map { "m\($0)" })) }
        #expect(throws: AccessError.invalidRequest("meetingIDs")) { try r.searchMeetings(SearchMeetingsRequest(query: "canary", meetingIDs: ["a' OR 1=1"])) }
        #expect(throws: AccessError.invalidRequest("limit must be 1…20")) { try r.searchMeetings(SearchMeetingsRequest(query: "canary", limit: 21)) }
        #expect(throws: AccessError.invalidRequest("limit must be 1…50")) { try r.listMeetings(ListMeetingsRequest(limit: 0)) }
        #expect(throws: AccessError.invalidRequest("startFrom must be before startBefore")) {
            try r.listMeetings(ListMeetingsRequest(filter: MeetingFilter(startFrom: Date(timeIntervalSince1970: 10), startBefore: Date(timeIntervalSince1970: 5))))
        }
        #expect(throws: AccessError.invalidRequest("meetingID")) { try r.getMeeting(GetMeetingRequest(meetingID: "../../etc", section: .notes)) }
        #expect(throws: AccessError.invalidRequest("a time range applies to the transcript")) { try r.getMeeting(GetMeetingRequest(meetingID: m.rawValue, section: .notes, startNs: 0)) }
        for q in ["canary\" OR text:*", "NEAR(canary rollback)", "text : canary", "canary'); DROP TABLE meetings;--", "^canary", "canary AND NOT plan",
                  "{text speaker}: canary", "canary 🚀", "c*a*n*a*r*y"] {
            _ = try r.searchMeetings(SearchMeetingsRequest(query: q))   // never throws an SQLite error
        }
        #expect(try r.listMeetings(ListMeetingsRequest()).meetings.count == 1)   // the library is intact
        #expect(try r.searchMeetings(SearchMeetingsRequest(query: "canary'); DROP TABLE meetings;--")).passages.first?.lines.contains { $0.text.contains("canary") } == true)
    }

    @Test func cancellationAndDeadlineStopWork() throws {
        let lib = try RetrievalLibrary()
        try lib.meeting("Ops", lines: ["deploy the canary"])
        #expect(throws: AccessError.cancelled) { try lib.reader.searchMeetings(SearchMeetingsRequest(query: "canary"), context: AccessContext(isCancelled: { true })) }
        #expect(throws: AccessError.deadlineExceeded) {
            try lib.reader.listMeetings(ListMeetingsRequest(), context: AccessContext(deadline: Date(timeIntervalSinceNow: -1), isCancelled: { false }))
        }
    }

    @Test func passagesCarryCurrentCitationsAndAuthorship() throws {
        let lib = try RetrievalLibrary()
        let m = try lib.meeting("Ops", lines: ["deploy the canary tonight"], notes: ["Remember the canary checklist"])
        let r = try lib.reader.searchMeetings(SearchMeetingsRequest(query: "canary"))
        #expect(Set(r.passages.map(\.source)) == ["transcript", "userNote"])
        for p in r.passages {
            for l in p.lines { if case .current = lib.reader.resolve(l.citation) {} else { Issue.record("citation does not resolve: \(l.citation)") } }
            #expect(p.meetingID == m.rawValue && p.revision != nil)
        }
        #expect(r.limitations.contains { $0.contains("not meaning") } && r.limitations.contains { $0.contains("not a confidence") })
    }
}
