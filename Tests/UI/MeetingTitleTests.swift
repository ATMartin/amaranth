import Testing
import Foundation
import Domain
import Storage
@testable import Presentation

@Suite("Meeting rename")
struct MeetingTitleTests {
    /// T26: an empty or whitespace-only title keeps the old one; titles are trimmed; unchanged titles are no-ops.
    @Test func emptyTitlesKeepTheOldTitle() {
        #expect(MeetingTitle.renamed(from: "Standup", to: "") == nil)
        #expect(MeetingTitle.renamed(from: "Standup", to: "  \n ") == nil)
        #expect(MeetingTitle.renamed(from: "Standup", to: " Standup ") == nil)
        #expect(MeetingTitle.renamed(from: "Standup", to: "  Weekly standup ") == "Weekly standup")
    }

    /// Renaming updates the title search entry (what LibraryModel.rename stores).
    @Test func renamedTitleIsSearchable() throws {
        let (store, root) = try tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        var m = Meeting(id: MeetingID("m-rename"), title: "Standup", createdAt: Date(), captureState: .captured, duration: .seconds(60))
        try store.upsertMeeting(m)
        m.title = try #require(MeetingTitle.renamed(from: m.title, to: "Quarterly zebra review"))
        try store.upsertMeeting(m)
        #expect(try store.search("zebra").contains { $0.meetingID == m.id })
        #expect(try store.search("Standup").isEmpty)
    }
}
