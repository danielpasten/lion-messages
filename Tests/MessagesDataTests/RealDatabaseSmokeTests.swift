import Foundation
import XCTest
@testable import MessagesData

/// Opt-in, read-only smoke test against the real ~/Library/Messages/chat.db.
/// Run with `LION_REAL_DB_SMOKE=1 swift test --filter RealDatabaseSmokeTests`.
/// Prints ONLY counts, timings and booleans — never message text, handles or names.
/// Skips when not opted in or when the database can't be opened (no Full Disk Access).
final class RealDatabaseSmokeTests: XCTestCase {
    func testRealDatabaseCountsAndTimings() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LION_REAL_DB_SMOKE"] == "1", "opt-in only")
        let path = ChatDatabase.defaultPath
        let service = LiveMessagesService(databasePath: path, contacts: ContactResolver(entries: []),
                                          sender: MessageSender(runner: { _ in XCTFail("must not send"); return nil }))
        let access = await service.checkAccess()
        try XCTSkipUnless(access == .granted, "chat.db not readable")

        var start = Date()
        let convs = try await service.loadConversations()
        let convMS = Int(Date().timeIntervalSince(start) * 1000)
        print("SMOKE conversations=\(convs.count) ms=\(convMS) groups=\(convs.filter(\.isGroup).count) emptyPreviews=\(convs.filter { $0.lastMessagePreview.isEmpty }.count)")

        if let first = convs.first {
            start = Date()
            let messages = try await service.loadMessages(in: first, limit: 200)
            let msgMS = Int(Date().timeIntervalSince(start) * 1000)
            print("SMOKE firstConversationMessages=\(messages.count) ms=\(msgMS) emptyTexts=\(messages.filter { $0.text.isEmpty }.count)")
        }

        // Decoder rate on the newest attributedBody-only rows.
        let conn = try SQLiteConnection(readOnlyPath: path)
        var sampled = 0, decoded = 0, decodedNonEmpty = 0
        var failurePrefixes: [String: Int] = [:]
        try conn.query("""
            SELECT attributedBody FROM message
            WHERE (text IS NULL OR text = '') AND attributedBody IS NOT NULL
            ORDER BY ROWID DESC LIMIT 2000
            """) { row in
            guard let data = row.data(0) else { return }
            sampled += 1
            if let s = AttributedBodyDecoder.decode(data) {
                decoded += 1
                if !s.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    decodedNonEmpty += 1
                }
            } else {
                // Structural header bytes only (first 16 = "streamtyped" header), never payload.
                let key = data.prefix(16).map { String(format: "%02x", $0) }.joined()
                failurePrefixes[key, default: 0] += 1
            }
        }
        print("SMOKE attributedBodySampled=\(sampled) decoded=\(decoded) decodedNonEmpty=\(decodedNonEmpty) failureHeaderKinds=\(failurePrefixes.count)")
        if sampled > 0 {
            XCTAssertGreaterThanOrEqual(Double(decoded) / Double(sampled), 0.99)
        }
        XCTAssertLessThan(convMS, 1000)
    }

    /// Attachments + link previews on real data. Prints ONLY counts, timings and histograms of
    /// kinds/structural failure reasons — never URLs, titles, names or paths.
    func testRealDatabaseAttachmentsAndLinkPreviews() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LION_REAL_DB_SMOKE"] == "1", "opt-in only")
        let path = ChatDatabase.defaultPath
        let service = LiveMessagesService(databasePath: path, contacts: ContactResolver(entries: []),
                                          sender: MessageSender(runner: { _ in XCTFail("must not send"); return nil }))
        let access = await service.checkAccess()
        try XCTSkipUnless(access == .granted, "chat.db not readable")
        let conn = try SQLiteConnection(readOnlyPath: path)

        // Pages: the 3 most recent conversations plus the chats holding the newest image
        // attachment and the newest URL balloon.
        let convs = try await service.loadConversations()
        var chatIDs = convs.prefix(3).map(\.id)
        for sql in [
            """
            SELECT cmj.chat_id FROM attachment a JOIN message_attachment_join j ON j.attachment_id = a.ROWID
            JOIN chat_message_join cmj ON cmj.message_id = j.message_id
            WHERE a.mime_type LIKE 'image/%' AND COALESCE(a.hide_attachment, 0) = 0 ORDER BY a.ROWID DESC LIMIT 1
            """,
            """
            SELECT cmj.chat_id FROM message m JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            WHERE m.balloon_bundle_id = '\(LinkPreviewDecoder.urlBalloonBundleID)' ORDER BY m.ROWID DESC LIMIT 1
            """,
        ] {
            if let id = try conn.scalarInt64(sql), !chatIDs.contains(id) { chatIDs.append(id) }
        }
        var pageCount = 0, attachments = 0, withFile = 0, stickers = 0, previews = 0, previewImages = 0
        var kinds: [String: Int] = [:]
        var worstMS = 0
        for id in chatIDs {
            guard let conv = convs.first(where: { $0.id == id }) else { continue }
            let start = Date()
            let messages = try await service.loadMessages(in: conv, limit: 300)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            worstMS = max(worstMS, ms)
            pageCount += 1
            let atts = messages.flatMap(\.attachments)
            attachments += atts.count
            withFile += atts.filter { $0.fileURL != nil }.count
            stickers += atts.filter(\.isSticker).count
            for a in atts { kinds[a.kind.rawValue, default: 0] += 1 }
            previews += messages.filter { $0.linkPreview != nil }.count
            previewImages += messages.filter { $0.linkPreview?.imageFileURL != nil }.count
            print("SMOKE page messages=\(messages.count) ms=\(ms) attachments=\(atts.count) linkPreviews=\(messages.filter { $0.linkPreview != nil }.count)")
        }
        print("SMOKE pages=\(pageCount) worstMS=\(worstMS) attachments=\(attachments) withExistingFile=\(withFile) stickers=\(stickers) kinds=\(kinds.sorted { $0.key < $1.key }) linkPreviews=\(previews) previewImageFiles=\(previewImages)")

        // Newest 1,000 payload-bearing URL balloons, decoded directly.
        var payloads: [(Int64, Data)] = []
        try conn.query("""
            SELECT ROWID, payload_data FROM message
            WHERE balloon_bundle_id = '\(LinkPreviewDecoder.urlBalloonBundleID)' AND payload_data IS NOT NULL
            ORDER BY ROWID DESC LIMIT 1000
            """) { r in if let d = r.data(1) { payloads.append((r.int64(0), d)) } }
        var records: [Int64: [ChatDatabase.AttachmentRecord]] = [:]
        let ids = payloads.map { String($0.0) }.joined(separator: ",")
        if !ids.isEmpty {
            try conn.query("""
                SELECT j.message_id, a.ROWID, a.filename FROM message_attachment_join j
                JOIN attachment a ON a.ROWID = j.attachment_id
                WHERE j.message_id IN (\(ids)) ORDER BY j.message_id, j.ROWID
                """) { r in
                records[r.int64(0), default: []].append(ChatDatabase.AttachmentRecord(
                    id: r.int64(1), path: r.string(2).flatMap(ChatDatabase.expandedPath), uti: nil, mimeType: nil,
                    transferName: nil, byteCount: nil, isSticker: false, isHidden: true))
            }
        }
        var decoded = 0, withTitle = 0, withSummary = 0, withSite = 0, withImageIndex = 0, withImageFile = 0, withIconFile = 0
        var failures: [String: Int] = [:]
        let start = Date()
        for (id, data) in payloads {
            guard let preview = ChatDatabase.linkPreview(payload: data, attachments: records[id] ?? []) else {
                failures[Self.failureReason(data), default: 0] += 1
                continue
            }
            decoded += 1
            if preview.title != nil { withTitle += 1 }
            if preview.summary != nil { withSummary += 1 }
            if preview.siteName != nil { withSite += 1 }
            if LinkPreviewDecoder.decode(data)?.imageAttachmentIndex != nil { withImageIndex += 1 }
            if preview.imageFileURL != nil { withImageFile += 1 }
            if preview.iconFileURL != nil { withIconFile += 1 }
        }
        let decodeMS = Int(Date().timeIntervalSince(start) * 1000)
        print("SMOKE urlBalloons=\(payloads.count) decoded=\(decoded) withTitle=\(withTitle) withSummary=\(withSummary) withSiteName=\(withSite) withImageIndex=\(withImageIndex) withImageFile=\(withImageFile) withIconFile=\(withIconFile) ms=\(decodeMS) failures=\(failures)")
        if !payloads.isEmpty {
            XCTAssertGreaterThanOrEqual(Double(decoded) / Double(payloads.count), 0.95)
        }
        XCTAssertLessThan(worstMS, 1000)
    }

    /// Structural reason a payload did not decode (no values).
    private static func failureReason(_ data: Data) -> String {
        guard data.starts(with: Data("bplist00".utf8)) else { return "notBplist" }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return "unparseable" }
        guard let objects = plist["$objects"] as? [Any], let top = plist["$top"] as? [String: Any],
              let rootRef = top["root"], let ri = KeyedArchiveUID.value(of: rootRef), ri < objects.count,
              let root = objects[ri] as? [String: Any] else { return "noRoot" }
        guard let mref = root["richLinkMetadata"] else { return "noMetadataKey" }
        guard let mi = KeyedArchiveUID.value(of: mref), mi > 0, mi < objects.count,
              let meta = objects[mi] as? [String: Any] else { return "nullMetadata" }
        let hasURLKey = meta["originalURL"] != nil || meta["URL"] != nil
        return hasURLKey ? "badURL" : "noURLKeys"
    }
}
