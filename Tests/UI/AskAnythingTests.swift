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
    }
}
