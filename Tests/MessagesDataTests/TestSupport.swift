import Foundation
import SQLite3
import XCTest

/// Builds typedstream blobs the same way Messages does, via NSArchiver (looked up dynamically to
/// avoid deprecation warnings).
func typedstream(_ object: NSObject) -> Data? {
    guard let cls = NSClassFromString("NSArchiver") as AnyObject? else { return nil }
    return cls.perform(NSSelectorFromString("archivedDataWithRootObject:"), with: object)?
        .takeUnretainedValue() as? Data
}

func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("LionMessagesTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Read-write connection used only by tests to build synthetic chat.db fixtures.
final class FixtureDB {
    private var db: OpaquePointer?
    let path: String

    init(path: String) throws {
        self.path = path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw NSError(domain: "FixtureDB", code: 1)
        }
    }

    deinit { close() }

    func close() {
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    func exec(_ sql: String, file: StaticString = #filePath, line: UInt = #line) {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            XCTFail("SQL failed (\(rc)): \(err.map { String(cString: $0) } ?? "")", file: file, line: line)
            sqlite3_free(err)
        }
    }

    /// Runs one statement binding Int64 / Double / String / Data / nil values.
    func run(_ sql: String, _ values: [Any?], file: StaticString = #filePath, line: UInt = #line) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return XCTFail("prepare failed: \(String(cString: sqlite3_errmsg(db)))", file: file, line: line)
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in values.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, transient)
            case let v as Data:
                _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), transient) }
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        if sqlite3_step(stmt) != SQLITE_DONE {
            XCTFail("step failed: \(String(cString: sqlite3_errmsg(db)))", file: file, line: line)
        }
    }

    static let fullSchema = """
        CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE, id TEXT NOT NULL,
            country TEXT, service TEXT NOT NULL, uncanonicalized_id TEXT, person_centric_id TEXT);
        CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL,
            style INTEGER, state INTEGER, account_id TEXT, properties BLOB, chat_identifier TEXT,
            service_name TEXT, room_name TEXT, account_login TEXT, is_archived INTEGER DEFAULT 0,
            last_addressed_handle TEXT, display_name TEXT, group_id TEXT, is_filtered INTEGER DEFAULT 0);
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL,
            text TEXT, replace INTEGER DEFAULT 0, service_center TEXT, handle_id INTEGER DEFAULT 0,
            subject TEXT, country TEXT, attributedBody BLOB, version INTEGER DEFAULT 0,
            type INTEGER DEFAULT 0, service TEXT, account TEXT, error INTEGER DEFAULT 0,
            date INTEGER, date_read INTEGER, date_delivered INTEGER, is_delivered INTEGER DEFAULT 0,
            is_finished INTEGER DEFAULT 0, is_from_me INTEGER DEFAULT 0, is_read INTEGER DEFAULT 0,
            cache_has_attachments INTEGER DEFAULT 0, item_type INTEGER DEFAULT 0,
            group_title TEXT, associated_message_guid TEXT, associated_message_type INTEGER DEFAULT 0,
            is_audio_message INTEGER DEFAULT 0, date_retracted INTEGER DEFAULT 0, date_edited INTEGER DEFAULT 0);
        CREATE TABLE chat_message_join (chat_id INTEGER REFERENCES chat (ROWID) ON DELETE CASCADE,
            message_id INTEGER REFERENCES message (ROWID) ON DELETE CASCADE, message_date INTEGER DEFAULT 0,
            PRIMARY KEY (chat_id, message_id));
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER, UNIQUE(chat_id, handle_id));
        CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL, filename TEXT);
        CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
        CREATE INDEX chat_message_join_idx_message_date_id_chat_id ON chat_message_join (chat_id, message_date, message_id);
        """
}
