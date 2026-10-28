public import Foundation
public import Domain

/// The sidebar's folder filter (T40, user decision 2026-10-28: Granola-style rows rather than collapsible sections).
/// “All meetings” lists every meeting, filed or not; a folder row lists only that folder's meetings. Either way the list
/// keeps its day groups.
public enum LibraryFolders {
    public struct Row: Identifiable, Equatable, Sendable {
        /// nil = “All meetings”.
        public var folderID: FolderID?
        public var name: String
        public var count: Int
        public var id: String { folderID?.rawValue ?? "" }
    }

    public static let allMeetingsTitle = "All meetings"

    /// “All meetings” first, then each folder in the store's order, with how many (live) meetings each holds.
    public static func rows(_ folders: [Folder], items: [MeetingListItem]) -> [Row] {
        var counts: [FolderID: Int] = [:]
        for item in items { if let f = item.folderID { counts[f, default: 0] += 1 } }
        return [Row(folderID: nil, name: allMeetingsTitle, count: items.count)]
            + folders.map { Row(folderID: $0.id, name: $0.name, count: counts[$0.id] ?? 0) }
    }

    /// The meetings shown for `filter` (nil = all), in library order.
    public static func visible(_ items: [MeetingListItem], filter: FolderID?) -> [MeetingListItem] {
        guard let filter else { return items }
        return items.filter { $0.folderID == filter }
    }

    /// The filter to keep after folders change: a deleted folder falls back to “All meetings”.
    public static func validFilter(_ filter: FolderID?, folders: [Folder]) -> FolderID? {
        guard let filter, folders.contains(where: { $0.id == filter }) else { return nil }
        return filter
    }

    /// A folder's name for captions (search results, exports); nil when unfiled or the folder is gone.
    public static func name(_ id: FolderID?, in folders: [Folder]) -> String? {
        guard let id else { return nil }
        return folders.first { $0.id == id }?.name
    }

    /// The confirmation for Delete Folder…: meetings always stay.
    public static func deleteMessage(count: Int) -> String {
        switch count {
        case 0: "The folder is empty. No meetings are deleted."
        case 1: "Its meeting stays in All meetings. Only the folder is removed."
        default: "Its \(count) meetings stay in All meetings. Only the folder is removed."
        }
    }
}
