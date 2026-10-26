import Testing
import Foundation
import Domain
import Storage
@testable import Presentation

@Suite("Meeting people chip (T50)")
struct MeetingPeopleTests {
    @Test func parsesLinesAndCommas() {
        #expect(MeetingPeople.parse("Ana Ruiz, Ben\n\n  Carla  \nben,") == [Person(name: "Ana Ruiz"), Person(name: "Ben"), Person(name: "Carla")])
        #expect(MeetingPeople.parse(" \n , ").isEmpty)
    }

    @Test func existingPeopleKeepTheirSource() {
        let existing = [Person(name: "Ana", source: .calendar), Person(name: "Ben")]
        #expect(MeetingPeople.parse("ana\nBen\nDee", keeping: existing)
                == [Person(name: "ana", source: .calendar), Person(name: "Ben"), Person(name: "Dee")])
        #expect(MeetingPeople.parse(MeetingPeople.editableText(existing), keeping: existing) == existing, "an unchanged editor round-trips")
    }

    @Test func chipLabelShowsUpToTwoNames() {
        #expect(MeetingPeople.chipLabel([]) == "Add people…")
        #expect(MeetingPeople.chipLabel([Person(name: "Ana")]) == "Ana")
        #expect(MeetingPeople.chipLabel([Person(name: "Ana"), Person(name: "Ben")]) == "Ana, Ben")
        #expect(MeetingPeople.chipLabel(["Ana", "Ben", "Carla", "Dee"].map { Person(name: $0) }) == "Ana, Ben +2")
        #expect(MeetingPeople.fullList(["Ana", "Ben", "Carla"].map { Person(name: $0) }) == "People: Ana, Ben, Carla")
    }

    /// What the chip's Save does (LibraryModel.setPeople): stored, reloaded, and in the exports.
    @Test func savedPeoplePersist() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "amr-people-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let m = Meeting(title: "Sync", createdAt: Date())
        try store.upsertMeeting(m)
        try store.setPeople(MeetingPeople.parse("Ana, Ben"), for: m.id)
        #expect(try store.meeting(m.id)?.people.map(\.name) == ["Ana", "Ben"])
    }
}
