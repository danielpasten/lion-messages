import Foundation
import MessagesModel
import SQLite3
import os

let dataLog = Logger(subsystem: "LionMessages", category: "data")

/// Read-only access to chat.db. All SQLite work happens on one private serial queue; the
/// connection is opened lazily and reopened after I/O-level errors.
final class ChatDatabase: @unchecked Sendable {
    let path: String
    private let contacts: ContactResolver
    private let queue = DispatchQueue(label: "LionMessages.chatdb", qos: .userInitiated)
    private var connection: SQLiteConnection?
    private var schema: Schema?

    init(path: String, contacts: ContactResolver) {
        self.path = path
        self.contacts = contacts
    }

    /// The real home directory (not a sandbox container), used for chat.db and `~` paths.
    static var homeDirectory: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    static var defaultPath: String {
        (homeDirectory as NSString).appendingPathComponent("Library/Messages/chat.db")
    }

    // MARK: - Queue plumbing

    private func run<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async { cont.resume(with: Result { try body() }) }
        }
    }

    /// On the queue: runs `body` with an open connection, reopening once after a connection-level error.
    private func withConnection<T>(_ body: (SQLiteConnection, Schema) throws -> T) throws -> T {
        do {
            let (c, s) = try open()
            return try body(c, s)
        } catch let error as SQLiteError where error.shouldReopen {
            dataLog.notice("chat.db error \(error.code, privacy: .public); reopening")
            close()
            let (c, s) = try open()
            return try body(c, s)
        }
    }

    private func open() throws -> (SQLiteConnection, Schema) {
        if let connection, let schema { return (connection, schema) }
        let c = try SQLiteConnection(readOnlyPath: path)
        let s = try Schema(connection: c)
        connection = c
        schema = s
        return (c, s)
    }

    private func close() {
        connection = nil
        schema = nil
    }

    // MARK: - Access

    func checkAccess() async -> AccessState {
        let path = self.path
        // 1. POSIX probe: errno is the most reliable Full Disk Access signal.
        let fd = Darwin.open(path, O_RDONLY)
        if fd < 0 {
            let err = errno
            switch err {
            case EPERM, EACCES:
                return .fullDiskAccessDenied
            case ENOENT, ENOTDIR:
                let dir = (path as NSString).deletingLastPathComponent
                let dfd = Darwin.open(dir, O_RDONLY | O_DIRECTORY)
                if dfd >= 0 { Darwin.close(dfd); return .databaseMissing }
                let derr = errno
                return (derr == EPERM || derr == EACCES) ? .fullDiskAccessDenied : .databaseMissing
            default:
                return .failed("Could not open the Messages database (errno \(err)).")
            }
        }
        Darwin.close(fd)

        // 2. Confirm SQLite can actually read it.
        do {
            _ = try await run { try self.withConnection { c, _ in try c.scalarInt64("SELECT count(*) FROM chat") } }
            return .granted
        } catch let error as SQLiteError {
            queue.async { self.close() }
            dataLog.error("chat.db access check failed: \(error.code, privacy: .public)")
            switch error.primaryCode {
            case SQLITE_AUTH, SQLITE_CANTOPEN, SQLITE_PERM: return .fullDiskAccessDenied
            default: return .failed(error.errorDescription ?? "Database error \(error.code)")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Change token (for the watcher's safety-net poll)

    /// Cheap fingerprint that changes when another connection commits. Synchronous; call off-main.
    func changeToken() -> String? {
        queue.sync {
            try? withConnection { c, _ in
                let version = try c.scalarInt64("PRAGMA data_version") ?? 0
                let maxID = try c.scalarInt64("SELECT max(ROWID) FROM message") ?? 0
                return "\(version):\(maxID)"
            }
        }
    }

    // MARK: - Conversations

    func loadConversations() async throws -> [Conversation] {
        try await run {
            let result = try self.withConnection { c, s in try self.conversations(c, s) }
            dataLog.info("loaded \(result.count, privacy: .public) conversations")
            return result
        }
    }

    private func conversations(_ c: SQLiteConnection, _ s: Schema) throws -> [Conversation] {
        // All chat/handle pairs in one query.
        var participants: [Int64: [String]] = [:]
        try c.query("""
            SELECT chj.chat_id, h.id FROM chat_handle_join chj
            JOIN handle h ON h.ROWID = chj.handle_id
            ORDER BY chj.chat_id, h.ROWID
            """) { row in
            if let handle = row.string(1), !handle.isEmpty {
                participants[row.int64(0), default: []].append(handle)
            }
        }

        // Each chat with its newest candidate message (correlated subquery walks the
        // chat_message_join index newest-first and stops at the first match).
        let sql = """
            SELECT c.ROWID, c.guid, \(s.chat("chat_identifier")), \(s.chat("display_name")),
                   \(s.chat("service_name")), \(s.chat("style")),
                   m.ROWID, m.guid, \(s.msg("text")), \(s.msg("attributedBody")), m.date, m.is_from_me,
                   \(s.msg("cache_has_attachments"))
            FROM chat c
            JOIN message m ON m.ROWID = (
                SELECT cmj.message_id FROM chat_message_join cmj
                JOIN message m2 ON m2.ROWID = cmj.message_id
                WHERE cmj.chat_id = c.ROWID AND \(s.candidateFilter(alias: "m2"))
                ORDER BY \(s.newestFirst(alias: "m2"))
                LIMIT 1)
            """
        var result: [Conversation] = []
        var needsFallback: [Int] = []
        try c.query(sql) { row in
            let chatID = row.int64(0)
            let handles = participants[chatID] ?? []
            let identifier = row.string(2) ?? ""
            let style = row.int64OrNil(5)
            let isGroup = style.map { $0 == 43 } ?? (handles.count > 1)
            let hasAttachments = (row.int64OrNil(12) ?? 0) != 0
            let preview = MessageText.display(text: row.string(8), attributedBody: row.data(9), hasAttachments: hasAttachments)
            if preview == nil { needsFallback.append(result.count) }
            result.append(Conversation(
                id: chatID,
                guid: row.string(1) ?? "",
                chatIdentifier: identifier,
                serviceName: row.string(4) ?? "iMessage",
                isGroup: isGroup,
                participantHandles: handles,
                title: self.title(displayName: row.string(3), handles: handles, identifier: identifier),
                lastMessagePreview: preview ?? "",
                lastMessageDate: AppleDate.date(fromRaw: row.int64(10)),
                lastMessageIsFromMe: row.int64(11) != 0))
        }

        // Rare: the newest candidate decoded to nothing (e.g. an unsent message). Look further back.
        var dropped = Set<Int>()
        for index in needsFallback {
            if let last = try displayableRows(c, s, chatID: result[index].id, limit: 1).first {
                result[index].lastMessagePreview = last.text
                result[index].lastMessageDate = AppleDate.date(fromRaw: last.rawDate)
                result[index].lastMessageIsFromMe = last.isFromMe
            } else {
                dropped.insert(index)
            }
        }
        if !dropped.isEmpty {
            result = result.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
        }

        result.sort {
            let l = $0.lastMessageDate ?? .distantPast, r = $1.lastMessageDate ?? .distantPast
            return l != r ? l > r : $0.id > $1.id
        }
        return result
    }

    private func title(displayName: String?, handles: [String], identifier: String) -> String {
        if let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        if !handles.isEmpty { return handles.map { contacts.displayName(for: $0) }.joined(separator: ", ") }
        return identifier.isEmpty ? "Unknown" : contacts.displayName(for: identifier)
    }

    // MARK: - Messages

    func loadMessages(in conversation: Conversation, limit: Int) async throws -> [Message] {
        guard limit > 0 else { return [] }
        return try await run {
            let (rows, attachments) = try self.withConnection { c, s -> ([Row], [Int64: [AttachmentRecord]]) in
                let rows = try self.displayableRows(c, s, chatID: conversation.id, limit: limit)
                return (rows, try self.attachmentRecords(c, s, for: rows))
            }
            dataLog.info("loaded \(rows.count, privacy: .public) messages")
            return rows.reversed().map { row in
                let records = attachments[row.id] ?? []
                var handle = row.isFromMe ? nil : row.handle
                if !row.isFromMe, handle == nil, !conversation.isGroup { handle = conversation.participantHandles.first }
                return Message(
                    id: row.id,
                    guid: row.guid,
                    text: row.text,
                    isFromMe: row.isFromMe,
                    date: AppleDate.date(fromRaw: row.rawDate),
                    senderHandle: handle,
                    senderName: handle.map { self.contacts.displayName(for: $0) },
                    serviceName: row.service ?? conversation.serviceName,
                    hasAttachment: row.hasAttachment,
                    attachments: records.filter { !$0.isHidden }.map { $0.attachment() },
                    linkPreview: row.linkPayload.flatMap { Self.linkPreview(payload: $0, attachments: records) })
            }
        }
    }

    // MARK: - Attachments & link previews

    /// One message_attachment_join row with its attachment columns (hidden ones included).
    struct AttachmentRecord {
        var id: Int64
        var path: String?
        var uti: String?
        var mimeType: String?
        var transferName: String?
        var byteCount: Int64?
        var isSticker: Bool
        var isHidden: Bool

        /// Absolute path when the row has a filename and the file exists. Call on the db queue.
        var existingFileURL: URL? {
            guard let path, FileManager.default.fileExists(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        }

        func attachment() -> MessageAttachment {
            let name = transferName ?? path.map { ($0 as NSString).lastPathComponent }
            return MessageAttachment(
                id: id,
                kind: AttachmentKind.kind(mimeType: mimeType, uti: uti, path: path ?? transferName),
                fileURL: existingFileURL,
                mimeType: mimeType, uti: uti,
                displayName: name.flatMap { $0.isEmpty ? nil : $0 },
                byteCount: byteCount, isSticker: isSticker)
        }
    }

    /// Max ids per `IN (...)` list (well under SQLite's bound-parameter limit).
    static let attachmentChunkSize = 500

    /// All attachments (visible and hidden) of `rows`, keyed by message id, in join order.
    /// One query per chunk of message ids.
    private func attachmentRecords(_ c: SQLiteConnection, _ s: Schema, for rows: [Row]) throws -> [Int64: [AttachmentRecord]] {
        guard s.hasAttachmentTables else { return [:] }
        // With cache_has_attachments, only flagged rows can have any; otherwise ask for all.
        let ids = s.message.contains("cache_has_attachments")
            ? rows.filter { $0.hasAttachment || $0.linkPayload != nil }.map(\.id)
            : rows.map(\.id)
        guard !ids.isEmpty else { return [:] }

        let order = s.attachmentJoinHasRowID ? "j.message_id, j.ROWID, a.ROWID" : "j.message_id, a.ROWID"
        var result: [Int64: [AttachmentRecord]] = [:]
        var start = 0
        while start < ids.count {
            let chunk = Array(ids[start..<min(start + Self.attachmentChunkSize, ids.count)])
            start += chunk.count
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let sql = """
                SELECT j.message_id, a.ROWID, \(s.att("filename")), \(s.att("uti")), \(s.att("mime_type")),
                       \(s.att("transfer_name")), \(s.att("total_bytes")), \(s.att("is_sticker")),
                       \(s.att("hide_attachment"))
                FROM message_attachment_join j
                JOIN attachment a ON a.ROWID = j.attachment_id
                WHERE j.message_id IN (\(placeholders))
                ORDER BY \(order)
                """
            try c.query(sql, chunk) { r in
                let bytes = r.int64OrNil(6)
                result[r.int64(0), default: []].append(AttachmentRecord(
                    id: r.int64(1),
                    path: r.string(2).flatMap(Self.expandedPath),
                    uti: Self.nonEmpty(r.string(3)),
                    mimeType: Self.nonEmpty(r.string(4)),
                    transferName: Self.nonEmpty(r.string(5)),
                    byteCount: bytes.flatMap { $0 > 0 ? $0 : nil },
                    isSticker: (r.int64OrNil(7) ?? 0) != 0,
                    isHidden: (r.int64OrNil(8) ?? 0) != 0))
            }
        }
        return result
    }

    /// Decodes a URL balloon payload and maps its image/icon substitute indexes onto the
    /// message's attachments (join order). Call on the db queue (checks file existence).
    static func linkPreview(payload: Data, attachments: [AttachmentRecord]) -> LinkPreview? {
        guard let decoded = LinkPreviewDecoder.decode(payload) else { return nil }
        func file(_ index: Int?) -> URL? {
            guard let index, index >= 0, index < attachments.count else { return nil }
            return attachments[index].existingFileURL
        }
        return LinkPreview(url: decoded.url, title: decoded.title, summary: decoded.summary,
                           siteName: decoded.siteName,
                           imageFileURL: file(decoded.imageAttachmentIndex),
                           iconFileURL: file(decoded.iconAttachmentIndex))
    }

    /// Expands a leading `~` against the real home directory; returns nil for empty paths.
    static func expandedPath(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed == "~" { return homeDirectory }
        if trimmed.hasPrefix("~/") {
            return (homeDirectory as NSString).appendingPathComponent(String(trimmed.dropFirst(2)))
        }
        return trimmed
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    struct Row {
        var id: Int64
        var guid: String
        var text: String
        var rawDate: Int64
        var isFromMe: Bool
        var hasAttachment: Bool
        var service: String?
        var handle: String?
        /// payload_data, only for URL balloon rows.
        var linkPayload: Data?
    }

    /// Newest-first displayable messages of a chat. Pages through candidates because some rows
    /// only turn out to be empty after decoding attributedBody.
    private func displayableRows(_ c: SQLiteConnection, _ s: Schema, chatID: Int64, limit: Int) throws -> [Row] {
        let handleJoin = s.message.contains("handle_id") ? "LEFT JOIN handle h ON h.ROWID = m.handle_id" : ""
        let handleCol = handleJoin.isEmpty ? "NULL" : "h.id"
        let sql = """
            SELECT m.ROWID, m.guid, \(s.msg("text")), \(s.msg("attributedBody")), m.date, m.is_from_me,
                   \(s.msg("cache_has_attachments")), \(s.msg("service")), \(handleCol),
                   \(s.urlBalloonPayload(alias: "m"))
            FROM chat_message_join cmj
            JOIN message m ON m.ROWID = cmj.message_id
            \(handleJoin)
            WHERE cmj.chat_id = ? AND \(s.candidateFilter(alias: "m"))
            ORDER BY \(s.newestFirst(alias: "m"))
            LIMIT ? OFFSET ?
            """
        let batch = max(limit, 50)
        var offset = 0
        var rows: [Row] = []
        while rows.count < limit {
            var fetched = 0
            try c.query(sql, [chatID, batch, offset]) { r in
                fetched += 1
                let hasAttachment = (r.int64OrNil(6) ?? 0) != 0
                guard let text = MessageText.display(text: r.string(2), attributedBody: r.data(3), hasAttachments: hasAttachment) else { return }
                rows.append(Row(
                    id: r.int64(0), guid: r.string(1) ?? "", text: text, rawDate: r.int64(4),
                    isFromMe: r.int64(5) != 0, hasAttachment: hasAttachment,
                    service: r.string(7).flatMap { $0.isEmpty ? nil : $0 },
                    handle: r.string(8).flatMap { $0.isEmpty ? nil : $0 },
                    linkPayload: r.data(9).flatMap { $0.isEmpty ? nil : $0 }))
            }
            if fetched < batch { break }
            offset += batch
        }
        return Array(rows.prefix(limit))
    }
}

// MARK: - Schema discovery

/// Which optional columns exist in this chat.db, so queries can substitute NULL for missing ones.
struct Schema {
    let message: Set<String>
    let chat: Set<String>
    let chatMessageJoin: Set<String>
    let attachment: Set<String>
    let attachmentJoin: Set<String>
    /// Whether message_attachment_join is a rowid table (its ROWID gives attachment order).
    let attachmentJoinHasRowID: Bool

    init(connection c: SQLiteConnection) throws {
        message = try c.columns(of: "message")
        chat = try c.columns(of: "chat")
        chatMessageJoin = try c.columns(of: "chat_message_join")
        attachment = try c.columns(of: "attachment")
        attachmentJoin = try c.columns(of: "message_attachment_join")
        if attachmentJoin.contains("message_id") {
            attachmentJoinHasRowID = (try? c.execute("SELECT ROWID FROM message_attachment_join LIMIT 0")) != nil
        } else {
            attachmentJoinHasRowID = false
        }
    }

    var hasAttachmentTables: Bool {
        attachmentJoin.contains("message_id") && attachmentJoin.contains("attachment_id") && !attachment.isEmpty
    }

    func att(_ col: String) -> String {
        attachment.contains(col.lowercased()) ? "a.\(col)" : "NULL"
    }

    /// payload_data for URL balloon rows only (NULL otherwise or when the columns are missing).
    func urlBalloonPayload(alias a: String) -> String {
        guard message.contains("balloon_bundle_id"), message.contains("payload_data") else { return "NULL" }
        return "CASE WHEN \(a).balloon_bundle_id = '\(LinkPreviewDecoder.urlBalloonBundleID)' THEN \(a).payload_data END"
    }

    func msg(_ col: String, alias: String = "m") -> String {
        message.contains(col.lowercased()) ? "\(alias).\(col)" : "NULL"
    }

    func chat(_ col: String) -> String {
        chat.contains(col.lowercased()) ? "c.\(col)" : "NULL"
    }

    /// SQL filter for rows that may be displayable: normal items, no tapbacks, not unsent, and
    /// with some text, attributedBody, or attachment. Final emptiness is decided after decoding.
    func candidateFilter(alias a: String) -> String {
        var parts: [String] = []
        if message.contains("item_type") { parts.append("COALESCE(\(a).item_type, 0) = 0") }
        if message.contains("associated_message_type") {
            parts.append("COALESCE(\(a).associated_message_type, 0) NOT BETWEEN 2000 AND 3999")
        }
        if message.contains("date_retracted") { parts.append("COALESCE(\(a).date_retracted, 0) = 0") }
        var content: [String] = []
        if message.contains("text") { content.append("(\(a).text IS NOT NULL AND \(a).text <> '')") }
        if message.contains("attributedbody") { content.append("\(a).attributedBody IS NOT NULL") }
        if message.contains("cache_has_attachments") { content.append("COALESCE(\(a).cache_has_attachments, 0) <> 0") }
        if !content.isEmpty { parts.append("(" + content.joined(separator: " OR ") + ")") }
        return parts.isEmpty ? "1" : parts.joined(separator: " AND ")
    }

    func newestFirst(alias a: String) -> String {
        chatMessageJoin.contains("message_date")
            ? "cmj.message_date DESC, cmj.message_id DESC"
            : "\(a).date DESC, \(a).ROWID DESC"
    }
}

// MARK: - Helpers

enum AppleDate {
    /// `message.date` is relative to 2001-01-01 UTC: nanoseconds on macOS 10.13+, seconds before.
    static func date(fromRaw raw: Int64) -> Date {
        let seconds = raw.magnitude > 100_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw)
        return Date(timeIntervalSinceReferenceDate: seconds)
    }
}

enum MessageText {
    /// Display text for a row, or nil when it should be dropped.
    static func display(text: String?, attributedBody: Data?, hasAttachments: Bool) -> String? {
        var result = clean(text)
        if result.isEmpty, let body = attributedBody, let decoded = AttributedBodyDecoder.decode(body) {
            result = clean(decoded)
        }
        if result.isEmpty { return hasAttachments ? LionConstants.attachmentPlaceholder : nil }
        return result
    }

    private static func clean(_ s: String?) -> String {
        guard let s else { return "" }
        return s.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
