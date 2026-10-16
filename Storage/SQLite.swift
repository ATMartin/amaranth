import Foundation
import SQLite3

/// Minimal SQLite wrapper (system libsqlite3). Not thread-safe by itself: `MeetingStore` serializes all access.
final class SQLiteDB {
    struct Error: Swift.Error, CustomStringConvertible {
        let code: Int32
        let message: String
        var description: String { "SQLite \(code): \(message)" }
    }

    private(set) var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw Error(code: SQLITE_CANTOPEN, message: msg)
        }
        sqlite3_busy_timeout(handle, 5000)
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA foreign_keys=ON")
        // Deleted meeting content is overwritten in the file rather than left in free pages (T11 deletion guarantee).
        try exec("PRAGMA secure_delete=ON")
        try exec("PRAGMA synchronous=NORMAL")
    }

    deinit {
        for s in statements.values { sqlite3_finalize(s) }
        sqlite3_close(handle)
    }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw Error(code: sqlite3_errcode(handle), message: "\(msg) — \(sql.prefix(120))")
        }
    }

    enum Value {
        case int(Int64), double(Double), text(String), blob(Data), null
    }

    /// Runs a statement (cached by SQL text) with positional bindings; returns rows as column-name dictionaries.
    @discardableResult
    func run(_ sql: String, _ bindings: [Value] = []) throws -> [[String: Value]] {
        let stmt = try prepare(sql)
        defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
        for (i, b) in bindings.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch b {
            case .int(let v): rc = sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): rc = sqlite3_bind_double(stmt, idx, v)
            case .text(let v): rc = sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT_)
            case .blob(let v): rc = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT_) }
            case .null: rc = sqlite3_bind_null(stmt, idx)
            }
            guard rc == SQLITE_OK else { throw lastError(sql) }
        }
        var rows: [[String: Value]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw lastError(sql) }
            var row: [String: Value] = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: row[name] = .double(sqlite3_column_double(stmt, c))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(stmt, c)))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, c))
                    row[name] = .blob(n == 0 ? Data() : Data(bytes: sqlite3_column_blob(stmt, c), count: n))
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let v = try body()
            try exec("COMMIT")
            return v
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        if let s = statements[sql] { return s }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw lastError(sql) }
        statements[sql] = stmt
        return stmt
    }

    private func lastError(_ sql: String) -> Error {
        Error(code: sqlite3_errcode(handle), message: "\(String(cString: sqlite3_errmsg(handle))) — \(sql.prefix(120))")
    }
}

/// SQLITE_TRANSIENT is a C macro (a cast of -1) that Swift cannot import.
let SQLITE_TRANSIENT_ = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension SQLiteDB.Value {
    var int: Int64? { if case .int(let v) = self { v } else { nil } }
    var text: String? { if case .text(let v) = self { v } else { nil } }
    var blob: Data? { if case .blob(let v) = self { v } else { nil } }
    var double: Double? { if case .double(let v) = self { v } else if case .int(let v) = self { Double(v) } else { nil } }
}
