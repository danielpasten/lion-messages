import Foundation
import SQLite3

/// A SQLite failure. `message` comes from `sqlite3_errstr` (a generic description of the code),
/// never from row data, so it is safe to log and show.
struct SQLiteError: Error, LocalizedError, Equatable {
    let code: Int32
    let message: String

    init(code: Int32) {
        self.code = code
        self.message = String(cString: sqlite3_errstr(code))
    }

    var primaryCode: Int32 { code & 0xFF }
    var errorDescription: String? { "Database error \(code): \(message)" }

    /// Errors after which the connection is discarded and reopened.
    var shouldReopen: Bool {
        [SQLITE_IOERR, SQLITE_CORRUPT, SQLITE_NOTADB, SQLITE_CANTOPEN, SQLITE_MISUSE].contains(primaryCode)
    }
}

/// A read-only SQLite connection. Not thread-safe: use from one serial queue.
final class SQLiteConnection {
    private let db: OpaquePointer

    /// Opens `path` read-only (`SQLITE_OPEN_READONLY`, `query_only`). Never `immutable=1`, so
    /// committed WAL contents stay visible.
    init(readOnlyPath path: String, busyTimeoutMS: Int32 = 2000) throws {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK, let handle else {
            let code = handle.map { sqlite3_extended_errcode($0) } ?? rc
            if let handle { sqlite3_close_v2(handle) }
            throw SQLiteError(code: code == SQLITE_OK ? rc : code)
        }
        db = handle
        sqlite3_extended_result_codes(db, 1)
        sqlite3_busy_timeout(db, busyTimeoutMS)
        do {
            try execute("PRAGMA query_only = ON")
        } catch {
            sqlite3_close_v2(db)
            throw error
        }
    }

    deinit { sqlite3_close_v2(db) }

    func execute(_ sql: String) throws {
        try query(sql) { _ in }
    }

    /// Runs `sql`, binding `bindings` (Int64, String, or nil) in order, calling `row` per result row.
    /// The statement is always finalized.
    func query(_ sql: String, _ bindings: [Any?] = [], row: (SQLiteRow) throws -> Void) throws {
        var stmt: OpaquePointer?
        let prc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        guard prc == SQLITE_OK, let stmt else { throw SQLiteError(code: sqlite3_extended_errcode(db)) }

        for (i, value) in bindings.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch value {
            case let v as Int64: rc = sqlite3_bind_int64(stmt, idx, v)
            case let v as Int: rc = sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as String: rc = sqlite3_bind_text(stmt, idx, v, -1, sqliteTransient)
            default: rc = sqlite3_bind_null(stmt, idx)
            }
            guard rc == SQLITE_OK else { throw SQLiteError(code: rc) }
        }

        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                try row(SQLiteRow(stmt: stmt))
            } else if rc == SQLITE_DONE {
                return
            } else {
                throw SQLiteError(code: sqlite3_extended_errcode(db))
            }
        }
    }

    func scalarInt64(_ sql: String) throws -> Int64? {
        var result: Int64?
        try query(sql) { result = $0.isNull(0) ? nil : $0.int64(0) }
        return result
    }

    /// Lowercased column names of `table` (empty if the table does not exist).
    func columns(of table: String) throws -> Set<String> {
        var cols = Set<String>()
        try query("PRAGMA table_info(\(table))") { row in
            if let name = row.string(1) { cols.insert(name.lowercased()) }
        }
        return cols
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A view of the current row. Only valid inside the `query` row callback.
struct SQLiteRow {
    fileprivate let stmt: OpaquePointer

    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    func int64OrNil(_ i: Int32) -> Int64? { isNull(i) ? nil : int64(i) }

    func string(_ i: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, i) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, i))
        return String(decoding: UnsafeBufferPointer(start: ptr, count: count), as: UTF8.self)
    }

    func data(_ i: Int32) -> Data? {
        guard sqlite3_column_type(stmt, i) != SQLITE_NULL else { return nil }
        let ptr = sqlite3_column_blob(stmt, i)
        let count = Int(sqlite3_column_bytes(stmt, i))
        guard count > 0, let ptr else { return Data() }
        return Data(bytes: ptr, count: count)
    }
}
