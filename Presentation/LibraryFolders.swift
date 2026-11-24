public import Foundation
public import Domain

/// The sidebar's folder filter (T40, user decision 2026-10-28: Granola-style rows rather than collapsible sections).
/// “All meetings” lists every meeting, filed or not; “Unsorted” (T83) only the unfiled ones; a folder row only that
/// folder's meetings. Either way the list keeps its day groups.
public enum LibraryFolders {
    /// What the sidebar lists.
    public enum Filter: Hashable, Sendable {
        case all
        /// Meetings in no folder (T83).
        case unsorted
        case folder(FolderID)

        /// The folder shown, if a folder row is selected.
        public var folderID: FolderID? { if case .folder(let id) = self { id } else { nil } }

        /// The UserDefaults value: nil for All meetings (as before T83), a folder's ID, or a marker for Unsorted that no
        /// folder ID can equal (folder IDs are UUIDs).
        public var stored: String? {
            switch self {
            case .all: nil
            case .unsorted: Self.unsortedMarker
            case .folder(let id): id.rawValue
            }
        }
        public init(stored: String?) {
            switch stored {
            case nil, "": self = .all
            case Self.unsortedMarker: self = .unsorted
            case let id?: self = .folder(FolderID(id))
            }
        }
        static let unsortedMarker = "@unsorted"
    }

    public struct Row: Identifiable, Equatable, Sendable {
        public var filter: Filter
        public var name: String
        public var count: Int
        /// The folder a meeting dropped on this row moves into; nil (All meetings, Unsorted) unfiles it.
        public var folderID: FolderID? { filter.folderID }
        public var id: String { filter.stored ?? "" }
    }

    public static let allMeetingsTitle = "All meetings"
    public static let unsortedTitle = "Unsorted"

    /// “All meetings”, “Unsorted”, then each folder in the store's order, with how many (live) meetings each holds.
    public static func rows(_ folders: [Folder], items: [MeetingListItem]) -> [Row] {
        var counts: [FolderID: Int] = [:]
        var unfiled = 0
        for item in items { if let f = item.folderID { counts[f, default: 0] += 1 } else { unfiled += 1 } }
        return [Row(filter: .all, name: allMeetingsTitle, count: items.count), Row(filter: .unsorted, name: unsortedTitle, count: unfiled)]
            + folders.map { Row(filter: .folder($0.id), name: $0.name, count: counts[$0.id] ?? 0) }
    }

    /// The meetings shown for `filter`, in library order.
    public static func visible(_ items: [MeetingListItem], filter: Filter) -> [MeetingListItem] {
        switch filter {
        case .all: items
        case .unsorted: items.filter { $0.folderID == nil }
        case .folder(let id): items.filter { $0.folderID == id }
        }
    }

    /// The filter to keep after folders change: a deleted folder falls back to “All meetings”.
    public static func validFilter(_ filter: Filter, folders: [Folder]) -> Filter {
        guard case .folder(let id) = filter else { return filter }
        return folders.contains(where: { $0.id == id }) ? filter : .all
    }

    /// The filter after a recording starts in `folder` (T42): kept when it already lists the new card, else the
    /// recording's folder, or All meetings for an unfiled recording.
    public static func filter(_ filter: Filter, showingNewMeetingIn folder: FolderID?) -> Filter {
        switch filter {
        case .all: .all
        case .unsorted: folder.map(Filter.folder) ?? .unsorted
        case .folder(let id): id == folder ? filter : folder.map(Filter.folder) ?? .all
        }
    }

    /// The list's text when the filter shows no meetings.
    public static func emptyMessage(_ filter: Filter, libraryEmpty: Bool) -> String {
        if libraryEmpty { return "No recordings yet." }
        return switch filter {
        case .all: "No recordings yet."
        case .unsorted: "Every meeting is in a folder."
        case .folder: "No meetings in this folder. Drag a meeting here, or use Move to Folder in its menu."
        }
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

    /// Meetings dropped on a folder row (T41; nil = “All meetings” or “Unsorted”, which unfile): the ones to move. Meetings no longer in
    /// the library, ones already where they were dropped, and drops on a folder deleted meanwhile are ignored, so an
    /// invalid drop does nothing rather than raising an error.
    public static func dropMoves(_ dropped: [MeetingID], onto folder: FolderID?, items: [MeetingListItem], folders: [Folder]) -> [MeetingID] {
        if let folder, !folders.contains(where: { $0.id == folder }) { return [] }
        var seen = Set<MeetingID>()
        return dropped.filter { id in
            guard seen.insert(id).inserted, let item = items.first(where: { $0.id == id }) else { return false }
            return item.folderID != folder
        }
    }
}
