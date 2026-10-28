import Testing
import Foundation
import Domain
import Storage
@testable import Presentation

/// T40: the sidebar's folder filter (rows, counts, filtering) on a real store.
@Suite("Library folders")
struct LibraryFoldersTests {
    @Test func rowsCountsAndFilter() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "amr-folders-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let acme = try store.createFolder(name: "Acme"), hiring = try store.createFolder(name: "Hiring")
        let ids = (0..<4).map { MeetingID("m\($0)") }
        for (i, id) in ids.enumerated() { try store.upsertMeeting(Meeting(id: id, title: "M\(i)", createdAt: Date(timeIntervalSince1970: Double(i)))) }
        try store.moveMeeting(ids[0], to: acme.id)
        try store.moveMeeting(ids[2], to: acme.id)
        let items = try MeetingListItem.load(store)
        #expect(items.first { $0.id == ids[0] }?.folderID == acme.id)

        let rows = LibraryFolders.rows(try store.folders(), items: items)
        #expect(rows.map(\.name) == ["All meetings", "Acme", "Hiring"])
        #expect(rows.map(\.count) == [4, 2, 0])
        #expect(rows.map(\.folderID) == [nil, acme.id, hiring.id])
        #expect(Set(rows.map(\.id)).count == 3)

        #expect(LibraryFolders.visible(items, filter: nil).map(\.id) == items.map(\.id), "All meetings lists filed meetings too")
        #expect(LibraryFolders.visible(items, filter: acme.id).map(\.id) == [ids[2], ids[0]], "newest first, like the library")
        #expect(LibraryFolders.visible(items, filter: hiring.id).isEmpty)

        // A deleted folder falls back to All meetings; its meetings stay listed there.
        try store.deleteFolder(acme.id)
        let folders = try store.folders()
        #expect(LibraryFolders.validFilter(acme.id, folders: folders) == nil)
        #expect(LibraryFolders.validFilter(hiring.id, folders: folders) == hiring.id)
        #expect(try MeetingListItem.load(store).count == 4 && LibraryFolders.rows(folders, items: try MeetingListItem.load(store)).map(\.count) == [4, 0])
        #expect(LibraryFolders.name(hiring.id, in: folders) == "Hiring" && LibraryFolders.name(acme.id, in: folders) == nil && LibraryFolders.name(nil, in: folders) == nil)
    }

    @Test func deleteConfirmationSaysMeetingsStay() {
        #expect(LibraryFolders.deleteMessage(count: 0) == "The folder is empty. No meetings are deleted.")
        #expect(LibraryFolders.deleteMessage(count: 1).hasPrefix("Its meeting stays"))
        #expect(LibraryFolders.deleteMessage(count: 3) == "Its 3 meetings stay in All meetings. Only the folder is removed.")
    }

    /// T41: what a drop moves. Drops on the current folder, of unknown meetings, or on a deleted folder do nothing.
    @Test func dropsMoveOnlyWhatChanges() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "amr-drop-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let acme = try store.createFolder(name: "Acme")
        let a = MeetingID("a"), b = MeetingID("b")
        try store.upsertMeeting(Meeting(id: a, title: "A", createdAt: Date()))
        try store.upsertMeeting(Meeting(id: b, title: "B", createdAt: Date()))
        try store.moveMeeting(a, to: acme.id)
        let items = try MeetingListItem.load(store), folders = try store.folders()
        #expect(LibraryFolders.dropMoves([a, b, b], onto: acme.id, items: items, folders: folders) == [b])
        #expect(LibraryFolders.dropMoves([a, b], onto: nil, items: items, folders: folders) == [a], "All meetings unfiles")
        #expect(LibraryFolders.dropMoves([MeetingID("gone")], onto: acme.id, items: items, folders: folders).isEmpty)
        #expect(LibraryFolders.dropMoves([b], onto: FolderID("deleted"), items: items, folders: folders).isEmpty)
    }
}
