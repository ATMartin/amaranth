public import Foundation
public import Domain

/// Single-level folders (T39). A meeting is in at most one folder (`Meeting.folderID`, mirrored in `meetings.folder_id`).
/// Deleting a folder unfiles its meetings: it never deletes a meeting or touches its audio, transcript or notes.
extension MeetingStore {
    public enum FolderError: Error, Equatable, LocalizedError {
        case emptyName
        case duplicateName(String)
        case missingFolder

        public var errorDescription: String? {
            switch self {
            case .emptyName: "A folder needs a name."
            case .duplicateName(let name): "There is already a folder called “\(name)”."
            case .missingFolder: "That folder no longer exists."
            }
        }
    }

    /// All folders, in creation order (`sortOrder`), then by name.
    public func folders() throws -> [Folder] {
        try withDB { db in
            try db.run("SELECT json FROM folders ORDER BY sort_order, name COLLATE NOCASE").compactMap { $0["json"]?.blob }
                .map { try ContractCoding.decode(Folder.self, from: $0) }
        }
    }

    /// Creates a folder named `name`, trimmed. Throws `emptyName`, or `duplicateName` when another folder has the same
    /// name ignoring case.
    @discardableResult
    public func createFolder(name: String, now: Date = Date()) throws -> Folder {
        let name = try Self.folderName(name)
        return try withDB { db in
            try db.transaction {
                try Self.checkUnique(db, name, except: nil)
                let order = Int(try db.run("SELECT COALESCE(MAX(sort_order), -1) + 1 AS n FROM folders").first?["n"]?.int ?? 0)
                let folder = Folder(name: name, createdAt: now, sortOrder: order)
                try db.run("INSERT INTO folders (id, name, created_at, sort_order, json) VALUES (?,?,?,?,?)",
                           [.text(folder.id.rawValue), .text(name), .double(now.timeIntervalSince1970), .int(Int64(order)),
                            .blob(try ContractCoding.encode(folder))])
                return folder
            }
        }
    }

    /// Renames a folder (trimmed; unique ignoring case, though a folder may change the case of its own name).
    public func renameFolder(_ id: FolderID, to newName: String) throws {
        let name = try Self.folderName(newName)
        try withDB { db in
            try db.transaction {
                guard let row = try db.run("SELECT json FROM folders WHERE id=?", [.text(id.rawValue)]).first?["json"]?.blob else {
                    throw FolderError.missingFolder
                }
                try Self.checkUnique(db, name, except: id)
                var folder = try ContractCoding.decode(Folder.self, from: row)
                folder.name = name
                try db.run("UPDATE folders SET name=?, json=? WHERE id=?", [.text(name), .blob(try ContractCoding.encode(folder)), .text(id.rawValue)])
            }
        }
    }

    /// Deletes a folder. Its meetings (deleted ones too) become unfiled; only their folder changes. No-op when missing.
    public func deleteFolder(_ id: FolderID) throws {
        try withDB { db in
            try db.transaction {
                for row in try db.run("SELECT id, json FROM meetings WHERE folder_id=?", [.text(id.rawValue)]) {
                    guard let mid = row["id"]?.text, let blob = row["json"]?.blob else { continue }
                    var m = try ContractCoding.decode(Meeting.self, from: blob)
                    m.folderID = nil
                    try db.run("UPDATE meetings SET folder_id=NULL, json=? WHERE id=?", [.blob(try ContractCoding.encode(m)), .text(mid)])
                }
                try db.run("DELETE FROM folders WHERE id=?", [.text(id.rawValue)])
            }
        }
    }

    /// Files a meeting in `folder`, or unfiles it with nil. Throws `missingFolder` for a folder that doesn't exist;
    /// no-op for a missing or deleted meeting.
    public func moveMeeting(_ id: MeetingID, to folder: FolderID?) throws {
        // One transaction: a deleteFolder can't land between the check and the write and leave a dangling folder_id.
        try withDB { db in
            try db.transaction {
                if let folder, try db.run("SELECT 1 FROM folders WHERE id=?", [.text(folder.rawValue)]).isEmpty { throw FolderError.missingFolder }
                guard let row = try db.run("SELECT json FROM meetings WHERE id=?", [.text(id.rawValue)]).first?["json"]?.blob else { return }
                var m = try ContractCoding.decode(Meeting.self, from: row)
                guard m.deletedAt == nil else { return }
                m.folderID = folder
                try db.run("UPDATE meetings SET folder_id=?, json=? WHERE id=?",
                           [folder.map { .text($0.rawValue) } ?? .null, .blob(try ContractCoding.encode(m)), .text(id.rawValue)])
            }
        }
    }

    /// Live meetings in `folder`, newest first; nil = unfiled meetings.
    public func meetings(in folder: FolderID?) throws -> [Meeting] {
        try withDB { db in
            let rows = if let folder {
                try db.run("SELECT json FROM meetings WHERE folder_id=? AND deleted_at IS NULL ORDER BY created_at DESC", [.text(folder.rawValue)])
            } else {
                try db.run("SELECT json FROM meetings WHERE folder_id IS NULL AND deleted_at IS NULL ORDER BY created_at DESC")
            }
            return try rows.compactMap { $0["json"]?.blob }.map { try ContractCoding.decode(Meeting.self, from: $0) }
        }
    }

    static func folderName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw FolderError.emptyName }
        return name
    }

    static func checkUnique(_ db: SQLiteDB, _ name: String, except: FolderID?) throws {
        for row in try db.run("SELECT id, name FROM folders") {
            guard let other = row["name"]?.text, row["id"]?.text != except?.rawValue else { continue }
            if other.compare(name, options: [.caseInsensitive], locale: nil) == .orderedSame { throw FolderError.duplicateName(other) }
        }
    }
}
