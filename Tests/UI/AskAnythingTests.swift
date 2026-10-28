import Testing
import Foundation
import Domain
import DomainFixtures
import Storage
@testable import Presentation

@Suite("Ask anything field (T52)")
struct AskAnythingTests {
    func hit(_ meeting: String, _ ref: String) -> SearchHit {
        SearchHit(meetingID: MeetingID(meeting), meetingTitle: meeting.uppercased(), kind: .transcript, ref: ref, start: nil, snippet: ref)
    }

    @Test func groupsByMeetingInRankOrder() {
        let groups = AskResults.grouped([hit("a", "1"), hit("b", "2"), hit("a", "3"), hit("c", "4"), hit("b", "5")])
        #expect(groups.map(\.meetingID.rawValue) == ["a", "b", "c"])
        #expect(groups.map { $0.hits.map(\.ref) } == [["1", "3"], ["2", "5"], ["4"]])
        #expect(groups.first?.title == "A")
        #expect(AskResults.flattened(groups).map(\.ref) == ["1", "3", "2", "5", "4"], "arrow keys walk the panel's order")
    }

    @Test func arrowKeysClamp() {
        #expect(AskResults.move(nil, by: 1, count: 3) == 0)
        #expect(AskResults.move(nil, by: -1, count: 3) == 2)
        #expect(AskResults.move(0, by: -1, count: 3) == 0)
        #expect(AskResults.move(1, by: 1, count: 3) == 2)
        #expect(AskResults.move(2, by: 1, count: 3) == 2)
        #expect(AskResults.move(1, by: 1, count: 0) == nil)
    }

    @Test func thisMeetingNeedsAMeeting() {
        #expect(AskResults.effectiveScope(.thisMeeting, meeting: MeetingID("m")) == MeetingID("m"))
        #expect(AskResults.effectiveScope(.thisMeeting, meeting: nil) == nil)
        #expect(AskResults.effectiveScope(.allMeetings, meeting: MeetingID("m")) == nil)
    }

    /// T42: “This folder” is offered only while the sidebar shows a folder, and searches that folder only.
    @Test func thisFolderNeedsAShownFolder() {
        #expect(AskScope.options(folderShown: false) == [.thisMeeting, .allMeetings])
        #expect(AskScope.options(folderShown: true) == [.thisMeeting, .thisFolder, .allMeetings])
        #expect(AskScope.options(folderShown: true, meetingOpen: false) == [.thisFolder, .allMeetings], "no silent Meeting = All")
        #expect(AskResults.effectiveFolder(.thisFolder, folder: FolderID("f")) == FolderID("f"))
        #expect(AskResults.effectiveFolder(.thisFolder, folder: nil) == nil)
        #expect(AskResults.effectiveFolder(.allMeetings, folder: FolderID("f")) == nil)
        #expect(AskResults.effectiveScope(.thisFolder, meeting: MeetingID("m")) == nil, "a folder search is across meetings")
        #expect(AskScope.allCases.map { $0.label(short: true) } == ["Meeting", "Folder", "All"])
        #expect(AskScope.thisMeeting.label(short: false) == "This meeting")
    }

    @Test func searchScopedToOneFolder() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "amr-ask-folder-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let acme = try store.createFolder(name: "Acme")
        let a = Meeting(title: "Budget review", createdAt: Date()), b = Meeting(title: "Budget planning", createdAt: Date())
        try store.upsertMeeting(a); try store.upsertMeeting(b)
        try store.moveMeeting(a.id, to: acme.id)
        #expect(try store.search("budget", folder: acme.id).map(\.meetingID) == [a.id])
        #expect(try store.search("budget unicorn", folder: acme.id, anyTerm: true).map(\.meetingID) == [a.id])
        #expect(try store.search("budget", folder: FolderID("empty")).isEmpty)
        #expect(Set(try store.search("budget").map(\.meetingID)) == [a.id, b.id])
    }

    /// The engine behind the field: the scope limits hits to one meeting.
    @Test func searchScopedToOneMeeting() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "amr-ask-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let a = Meeting(title: "Budget review", createdAt: Date()), b = Meeting(title: "Budget planning", createdAt: Date())
        try store.upsertMeeting(a); try store.upsertMeeting(b)
        #expect(Set(try store.search("budget").map(\.meetingID)) == [a.id, b.id])
        #expect(try store.search("budget", in: a.id).map(\.meetingID) == [a.id])
        #expect(try store.search("budget", in: MeetingID("missing")).isEmpty)
        #expect(try store.search("budget unicorn").isEmpty)
        #expect(try store.search("budget unicorn", anyTerm: true).count == 2, "fallback: any of the words")
    }
}

@Suite("Ask follow-ups (T55)")
struct AskFollowUpTests {
    let turn = [AnswerTurn(question: "What does Bob want to do about Gary's contract?", answer: "Extend it six months.")]

    @Test func followUpsSearchWithThePreviousQuestion() {
        for q in ["And when does it currently run out?", "Why?", "What did he say about that?", "what about the budget", "So who decides?"] {
            #expect(AskFollowUp.isFollowUp(q), "\(q)")
            #expect(AskFollowUp.retrievalQuery(q, history: turn).hasPrefix("What does Bob want"), "\(q)")
        }
        for q in ["What did Leesa say about hiring at Gusto?", "Which meetings talked about security vulnerabilities?"] {
            #expect(!AskFollowUp.isFollowUp(q), "\(q)")
            #expect(AskFollowUp.retrievalQuery(q, history: turn) == q)
        }
        #expect(AskFollowUp.retrievalQuery("And when is it due?", history: []) == "And when is it due?", "no history: as asked")
        #expect(AskFollowUp.maxTurns == 3)
    }

    @Test func crossMeetingLabelsNameTheMeeting() {
        let p = Passage(meetingID: MeetingID("m"), meetingTitle: "Leesa 1:1", meetingDate: Date(timeIntervalSince1970: 1_792_000_000), source: .transcript, ref: "s",
                        lines: [.init(segmentID: TranscriptSegmentID("s"), start: .seconds(601), speaker: "Speaker 2", text: "Gusto is hiring.", matched: true)],
                        evidence: [], score: 1)
        #expect(AskPassages.label(p, acrossMeetings: false) == "10:01")
        #expect(AskPassages.label(p, acrossMeetings: true) == "Leesa 1:1 · 10:01")
        let rendered = AskPassages.render([p], acrossMeetings: true)[0]
        #expect(rendered.label.hasPrefix("Leesa 1:1 (") && rendered.text == "[10:01] Speaker 2: Gusto is hiring.")
    }
}
