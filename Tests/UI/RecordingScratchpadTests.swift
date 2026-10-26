import Testing
import Foundation
import Domain
import Storage
@testable import Presentation

@Suite("Recording scratchpad")
struct RecordingScratchpadTests {
    /// T33: text typed during recording appears in the meeting's Private scratchpad after Stop.
    @Test func typedTextAppearsInTheMeetingAfterStop() throws {
        let (store, root) = try tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = MeetingID("m-scratch")
        try store.upsertMeeting(Meeting(id: id, title: "Standup", createdAt: Date(), captureState: .captured, duration: .seconds(60)))
        #expect(try RecordingScratchpad.save("first thought", for: id, in: store))
        #expect(try !RecordingScratchpad.save("first thought", for: id, in: store))   // unchanged: no new revision
        #expect(try RecordingScratchpad.save("first thought\nfollow up with Dana", for: id, in: store))
        let detail = try #require(try MeetingDetail.load(store, id))
        #expect(detail.scratchpad?.text == "first thought\nfollow up with Dana")
        #expect(detail.scratchpad?.includeInSummary == false)
    }

    @Test func keepsTheUseInNotesChoice() throws {
        let (store, root) = try tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = MeetingID("m-scratch-include")
        try store.upsertMeeting(Meeting(id: id, title: "Standup", createdAt: Date(), captureState: .captured, duration: .seconds(60)))
        try store.saveScratchpad(ScratchpadRevision(meetingID: id, text: "a", includeInSummary: true, createdAt: Date()))
        try RecordingScratchpad.save("a b", for: id, in: store)
        #expect(try store.latestScratchpad(id)?.includeInSummary == true)
    }
}
