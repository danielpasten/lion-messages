import Foundation
import MessagesModel
import XCTest
@testable import MessagesData

/// Exercises `LiveMessagesService` against a synthetic chat.db. All names and numbers are fake.
final class ChatDatabaseTests: XCTestCase {
    private var dir: URL!
    private var dbPath: String!

    /// Seconds since 2001-01-01 used as the base for message dates.
    private let base: Int64 = 700_000_000
    private func ns(_ offset: Int64) -> Int64 { (base + offset) * 1_000_000_000 }

    override func setUpWithError() throws {
        dir = try makeTempDirectory()
        dbPath = dir.appendingPathComponent("chat.db").path
        try buildFixture()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeService(path: String? = nil) -> LiveMessagesService {
        LiveMessagesService(
            databasePath: path ?? dbPath,
            contacts: ContactResolver(entries: [
                (handle: "+1 (555) 123-0001", name: "Alex Demo"),
                (handle: "Friend@Example.com", name: "Sam Sample"),
            ]),
            sender: MessageSender(runner: { _ in XCTFail("must not send"); return nil }))
    }

    private var msgID: Int64 = 0

    private func addMessage(_ fx: FixtureDB, chat: Int64, text: String?, body: Data? = nil, handle: Int64 = 0,
                            fromMe: Bool = false, date: Int64, attachments: Bool = false,
                            itemType: Int = 0, assocType: Int = 0) {
        msgID += 1
        fx.run("""
            INSERT INTO message (ROWID, guid, text, attributedBody, handle_id, service, date, is_from_me,
                cache_has_attachments, item_type, associated_message_type)
            VALUES (?, ?, ?, ?, ?, 'iMessage', ?, ?, ?, ?, ?)
            """, [msgID, "MSG-\(msgID)", text, body, handle, date, fromMe ? 1 : 0, attachments ? 1 : 0, itemType, assocType])
        fx.run("INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (?, ?, ?)", [chat, msgID, date])
    }

    private func buildFixture() throws {
        let fx = try FixtureDB(path: dbPath)
        defer { fx.close() }
        fx.exec(FixtureDB.fullSchema)
        fx.exec("""
            INSERT INTO handle (ROWID, id, service) VALUES (1, '+15551230001', 'iMessage'),
                (2, 'friend@example.com', 'iMessage'), (3, '+15551230003', 'SMS');
            INSERT INTO chat (ROWID, guid, style, chat_identifier, service_name, display_name) VALUES
                (1, 'iMessage;-;+15551230001', 45, '+15551230001', 'iMessage', ''),
                (2, 'iMessage;+;chat100', 43, 'chat100', 'iMessage', 'Weekend Plans'),
                (3, 'iMessage;+;chat200', 43, 'chat200', 'iMessage', NULL),
                (4, 'iMessage;-;+15551230003', 45, '+15551230003', 'SMS', NULL),
                (5, 'iMessage;-;friend@example.com', 45, 'friend@example.com', 'iMessage', NULL),
                (6, 'iMessage;-;+15550000000', 45, '+15550000000', 'iMessage', NULL);
            INSERT INTO chat_handle_join VALUES (1, 1), (2, 2), (2, 3), (3, 1), (3, 2), (4, 3), (5, 2);
            """)
        let body = try XCTUnwrap(typedstream(NSAttributedString(string: "Reply via body 🎉")))

        // Chat 1 (1:1): text, attributedBody-only, attachment-only, then a tapback (skipped).
        addMessage(fx, chat: 1, text: "Hello there", handle: 1, date: ns(1))
        addMessage(fx, chat: 1, text: nil, body: body, fromMe: true, date: ns(2))
        addMessage(fx, chat: 1, text: "\u{FFFC}", handle: 1, date: ns(3), attachments: true)
        addMessage(fx, chat: 1, text: "Loved “Hello there”", handle: 1, date: ns(4), assocType: 2000)
        // Chat 2 (named group): normal messages, then a rename event and a tapback (both skipped).
        addMessage(fx, chat: 2, text: "Group hi", handle: 2, date: ns(0))
        addMessage(fx, chat: 2, text: "Group reply", fromMe: true, date: ns(6))
        addMessage(fx, chat: 2, text: nil, handle: 3, date: ns(7), itemType: 2)
        addMessage(fx, chat: 2, text: "Liked “Group reply”", handle: 3, date: ns(8), assocType: 2001)
        // Chat 3 (unnamed group), legacy seconds-based date.
        addMessage(fx, chat: 3, text: "  Seconds date  ", handle: 1, date: base + 2)
        // Chat 4: only a tapback -> not listed.
        addMessage(fx, chat: 4, text: "Emphasized “x”", handle: 3, date: ns(10), assocType: 2004)
        // Chat 5: newest row decodes to nothing (no attachment) -> preview falls back to the earlier one.
        addMessage(fx, chat: 5, text: "Earlier text", handle: 2, date: ns(-5))
        addMessage(fx, chat: 5, text: "\u{FFFC} ", handle: 2, date: ns(9))
        // Chat 6: no messages -> not listed.
    }

    func testCheckAccessGranted() async {
        let state = await makeService().checkAccess()
        XCTAssertEqual(state, .granted)
    }

    func testConversationsOrderingPreviewsAndTitles() async throws {
        let convs = try await makeService().loadConversations()
        XCTAssertEqual(convs.map(\.id), [2, 1, 3, 5])

        let group = convs[0]
        XCTAssertEqual(group.title, "Weekend Plans")
        XCTAssertTrue(group.isGroup)
        XCTAssertEqual(group.lastMessagePreview, "Group reply")
        XCTAssertTrue(group.lastMessageIsFromMe)
        XCTAssertEqual(group.participantHandles, ["friend@example.com", "+15551230003"])

        let oneToOne = convs[1]
        XCTAssertEqual(oneToOne.title, "Alex Demo")
        XCTAssertFalse(oneToOne.isGroup)
        XCTAssertEqual(oneToOne.guid, "iMessage;-;+15551230001")
        XCTAssertEqual(oneToOne.lastMessagePreview, LionConstants.attachmentPlaceholder)
        XCTAssertFalse(oneToOne.lastMessageIsFromMe)
        XCTAssertEqual(oneToOne.lastMessageDate, Date(timeIntervalSinceReferenceDate: TimeInterval(base + 3)))

        let unnamed = convs[2]
        XCTAssertEqual(unnamed.title, "Alex Demo, Sam Sample")
        XCTAssertEqual(unnamed.lastMessagePreview, "Seconds date")
        XCTAssertEqual(unnamed.lastMessageDate, Date(timeIntervalSinceReferenceDate: TimeInterval(base + 2)))

        let fallback = convs[3]
        XCTAssertEqual(fallback.lastMessagePreview, "Earlier text")
        XCTAssertEqual(fallback.lastMessageDate, Date(timeIntervalSinceReferenceDate: TimeInterval(base - 5)))
    }

    func testMessagesFilteringOrderAndSenders() async throws {
        let service = makeService()
        let convs = try await service.loadConversations()
        let oneToOne = try XCTUnwrap(convs.first { $0.id == 1 })

        let messages = try await service.loadMessages(in: oneToOne, limit: 50)
        XCTAssertEqual(messages.map(\.id), [1, 2, 3])
        XCTAssertEqual(messages.map(\.text), ["Hello there", "Reply via body 🎉", LionConstants.attachmentPlaceholder])
        XCTAssertEqual(messages[0].senderHandle, "+15551230001")
        XCTAssertEqual(messages[0].senderName, "Alex Demo")
        XCTAssertEqual(messages[0].date, Date(timeIntervalSinceReferenceDate: TimeInterval(base + 1)))
        XCTAssertTrue(messages[1].isFromMe)
        XCTAssertNil(messages[1].senderHandle)
        XCTAssertNil(messages[1].senderName)
        XCTAssertTrue(messages[2].hasAttachment)
        XCTAssertFalse(messages[0].hasAttachment)
        XCTAssertEqual(messages[0].serviceName, "iMessage")

        let lastTwo = try await service.loadMessages(in: oneToOne, limit: 2)
        XCTAssertEqual(lastTwo.map(\.id), [2, 3])

        let group = try XCTUnwrap(convs.first { $0.id == 2 })
        let groupMessages = try await service.loadMessages(in: group, limit: 50)
        XCTAssertEqual(groupMessages.map(\.text), ["Group hi", "Group reply"])
        XCTAssertEqual(groupMessages[0].senderName, "Sam Sample")

        let emptyChat = try XCTUnwrap(convs.first { $0.id == 5 })
        let emptyFiltered = try await service.loadMessages(in: emptyChat, limit: 50)
        XCTAssertEqual(emptyFiltered.map(\.text), ["Earlier text"])
    }

    func testOlderSchemaWithoutOptionalColumns() async throws {
        let path = dir.appendingPathComponent("old.db").path
        let fx = try FixtureDB(path: path)
        fx.exec("""
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT, service TEXT);
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, style INTEGER, chat_identifier TEXT, service_name TEXT);
            CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, handle_id INTEGER,
                service TEXT, date INTEGER, is_from_me INTEGER);
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            INSERT INTO handle VALUES (1, 'someone@example.com', 'iMessage');
            INSERT INTO chat VALUES (1, 'iMessage;-;someone@example.com', 45, 'someone@example.com', 'iMessage');
            INSERT INTO chat_handle_join VALUES (1, 1);
            INSERT INTO message VALUES (1, 'A', 'first', 1, 'iMessage', 400000000, 0), (2, 'B', 'second', 0, 'iMessage', 400000100, 1);
            INSERT INTO chat_message_join VALUES (1, 1), (1, 2);
            """)
        fx.close()
        let service = makeService(path: path)
        let convs = try await service.loadConversations()
        XCTAssertEqual(convs.count, 1)
        XCTAssertEqual(convs.first?.title, "someone@example.com")
        XCTAssertEqual(convs.first?.lastMessagePreview, "second")
        let messages = try await service.loadMessages(in: try XCTUnwrap(convs.first), limit: 10)
        XCTAssertEqual(messages.map(\.text), ["first", "second"])
    }

    func testSenderCategories() async throws {
        let path = dir.appendingPathComponent("filtered.db").path
        let fx = try FixtureDB(path: path)
        fx.exec(FixtureDB.fullSchema)
        fx.exec("ALTER TABLE chat ADD COLUMN is_blackholed INTEGER DEFAULT 0")
        fx.exec("""
            INSERT INTO handle (ROWID, id, service) VALUES (1, '+15559990001', 'SMS'), (2, '+15559990002', 'SMS'),
                (3, '+15551230001', 'iMessage'), (4, '+15559990004', 'SMS'), (5, '+15559990005', 'SMS'),
                (6, '+15559990006', 'SMS');
            INSERT INTO chat (ROWID, guid, style, chat_identifier, service_name, is_filtered, is_blackholed) VALUES
                (1, 'SMS;-;+15559990001', 45, '+15559990001', 'SMS', 1, 0),
                (2, 'SMS;-;+15559990002', 45, '+15559990002', 'SMS', 1, 0),
                (3, 'iMessage;-;+15551230001', 45, '+15551230001', 'iMessage', 1, 0),
                (4, 'SMS;-;+15559990004', 45, '+15559990004', 'SMS', 2, 0),
                (5, 'SMS;-;+15559990005', 45, '+15559990005', 'SMS', 0, 1),
                (6, 'SMS;-;+15559990006', 45, '+15559990006', 'SMS', 0, 0);
            INSERT INTO chat_handle_join VALUES (1, 1), (2, 2), (3, 3), (4, 4), (5, 5), (6, 6);
            """)
        // 1: filtered, never answered. 2: filtered, but answered. 3: filtered, but a contact.
        // 4: junk. 5: blocked. 6: never filtered.
        for chat in Int64(1)...6 { addMessage(fx, chat: chat, text: "hi \(chat)", handle: chat, date: ns(chat)) }
        addMessage(fx, chat: 2, text: "who's this?", fromMe: true, date: ns(20))
        fx.close()

        let convs = try await makeService(path: path).loadConversations()
        let byID = Dictionary(uniqueKeysWithValues: convs.map { ($0.id, $0.senderCategory) })
        XCTAssertEqual(byID, [1: .unknown, 2: .known, 3: .known, 4: .spam, 5: .spam, 6: .known])
    }

    func testPinKeysFromMessagesPreferences() {
        let data: [String: Any] = [
            "pP": ["+15551230001", "IMESSAGE;+;CHAT100", "Friend@Example.com", "+15551230001", 42, "  "],
            "pV": 2,
        ]
        XCTAssertEqual(MessagesPinning.keys(fromPinData: data), ["+15551230001", "chat100", "friend@example.com"])
        XCTAssertEqual(MessagesPinning.keys(fromPinData: nil), [])
        XCTAssertEqual(MessagesPinning.keys(fromPinData: ["pP": "nope"]), [])
    }

    func testPinKeyMatchesConversations() async throws {
        let convs = try await makeService().loadConversations()
        let keys = Set(MessagesPinning.keys(fromPinData: ["pP": ["IMESSAGE;+;CHAT100", "+15551230001"]]))
        XCTAssertEqual(convs.filter { keys.contains($0.pinKey) }.map(\.id).sorted(), [1, 2])
    }

    func testReactionResolver() {
        typealias R = ReactionResolver.Row
        let rows: [R] = [
            R(targetGUID: "p:0/A", type: 2000, emoji: nil, isFromMe: false, handle: "+1", senderName: "Alex"),
            R(targetGUID: "p:0/A", type: 2001, emoji: nil, isFromMe: true, handle: nil, senderName: nil),
            // Alex changes their mind: the like replaces the love.
            R(targetGUID: "p:0/A", type: 2001, emoji: nil, isFromMe: false, handle: "+1", senderName: "Alex"),
            // A removal of something else does nothing; of the current one removes it.
            R(targetGUID: "p:0/A", type: 3003, emoji: nil, isFromMe: true, handle: nil, senderName: nil),
            R(targetGUID: "bp:B", type: 2006, emoji: "🔥", isFromMe: false, handle: "+2", senderName: "Sam"),
            R(targetGUID: "p:1/C", type: 2003, emoji: nil, isFromMe: true, handle: nil, senderName: nil),
            R(targetGUID: "p:1/C", type: 3003, emoji: nil, isFromMe: true, handle: nil, senderName: nil),
            R(targetGUID: "p:0/D", type: 2006, emoji: "  ", isFromMe: true, handle: nil, senderName: nil),
            R(targetGUID: "p:0/D", type: 2007, emoji: nil, isFromMe: true, handle: nil, senderName: nil),
        ]
        let result = ReactionResolver.resolve(rows)
        XCTAssertEqual(result["A"], [
            Reaction(kind: .like, isFromMe: true, senderHandle: nil, senderName: nil),
            Reaction(kind: .like, isFromMe: false, senderHandle: "+1", senderName: "Alex"),
        ])
        XCTAssertEqual(result["B"], [Reaction(kind: .emoji("🔥"), isFromMe: false, senderHandle: "+2", senderName: "Sam")])
        XCTAssertNil(result["C"])
        XCTAssertNil(result["D"])
    }

    func testReactionsLoadWithMessages() async throws {
        let path = dir.appendingPathComponent("reactions.db").path
        let fx = try FixtureDB(path: path)
        fx.exec(FixtureDB.fullSchema)
        fx.exec("ALTER TABLE message ADD COLUMN associated_message_emoji TEXT")
        fx.exec("""
            INSERT INTO handle (ROWID, id, service) VALUES (1, '+15551230001', 'iMessage');
            INSERT INTO chat (ROWID, guid, style, chat_identifier, service_name) VALUES
                (1, 'iMessage;-;+15551230001', 45, '+15551230001', 'iMessage');
            INSERT INTO chat_handle_join VALUES (1, 1);
            """)
        addMessage(fx, chat: 1, text: "Dinner at 7?", handle: 1, date: ns(1))
        let first = "MSG-\(msgID)"
        addMessage(fx, chat: 1, text: "Perfect", fromMe: true, date: ns(2))
        let second = "MSG-\(msgID)"
        fx.run("""
            INSERT INTO message (ROWID, guid, text, handle_id, date, is_from_me, associated_message_guid,
                associated_message_type, associated_message_emoji) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [100, "R1", "Liked “Dinner at 7?”", 0, ns(3), 1, "p:0/" + first, 2001, nil])
        fx.run("INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, 100, ?)", [ns(3)])
        fx.run("""
            INSERT INTO message (ROWID, guid, text, handle_id, date, is_from_me, associated_message_guid,
                associated_message_type, associated_message_emoji) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [101, "R2", "Reacted 🎉", 1, ns(4), 0, "p:0/" + second, 2006, "🎉"])
        fx.run("INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, 101, ?)", [ns(4)])
        fx.close()

        let service = makeService(path: path)
        let convs = try await service.loadConversations()
        let conv = try XCTUnwrap(convs.first)
        XCTAssertEqual(conv.lastMessagePreview, "Perfect")
        let messages = try await service.loadMessages(in: conv, limit: 10)
        XCTAssertEqual(messages.map(\.text), ["Dinner at 7?", "Perfect"])
        XCTAssertEqual(messages[0].reactions, [Reaction(kind: .like, isFromMe: true, senderHandle: nil, senderName: nil)])
        XCTAssertEqual(messages[1].reactions, [Reaction(kind: .emoji("🎉"), isFromMe: false,
                                                        senderHandle: "+15551230001", senderName: "Alex Demo")])
    }

    func testMissingDatabase() async {
        let missing = dir.appendingPathComponent("nope/chat.db").path
        let state1 = await makeService(path: missing).checkAccess()
        XCTAssertEqual(state1, .databaseMissing)
        let state2 = await makeService(path: dir.appendingPathComponent("absent.db").path).checkAccess()
        XCTAssertEqual(state2, .databaseMissing)
    }

    func testUnreadableDatabaseReportsDenied() async throws {
        let path = dir.appendingPathComponent("locked.db").path
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data("x".utf8)))
        XCTAssertEqual(chmod(path, 0), 0)
        defer { chmod(path, 0o600) }
        let state = await makeService(path: path).checkAccess()
        XCTAssertEqual(state, .fullDiskAccessDenied)
    }

    func testCorruptDatabaseReportsFailed() async throws {
        let path = dir.appendingPathComponent("garbage.db").path
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data(repeating: 0x5A, count: 4096)))
        let state = await makeService(path: path).checkAccess()
        guard case .failed = state else { return XCTFail("expected .failed, got \(state)") }
    }

    func testReadOnlyConnectionCannotWrite() throws {
        let conn = try SQLiteConnection(readOnlyPath: dbPath)
        XCTAssertThrowsError(try conn.execute("DELETE FROM message"))
        XCTAssertEqual(try conn.scalarInt64("SELECT count(*) FROM message"), 12)
    }

    func testAppleDateConversion() {
        XCTAssertEqual(AppleDate.date(fromRaw: 700_000_000), Date(timeIntervalSinceReferenceDate: 700_000_000))
        XCTAssertEqual(AppleDate.date(fromRaw: 700_000_000_500_000_000),
                       Date(timeIntervalSinceReferenceDate: 700_000_000.5))
        _ = AppleDate.date(fromRaw: .min) // must not trap
    }

    func testContactResolverPhoneAndEmailMatching() {
        let resolver = ContactResolver(entries: [
            (handle: "+1 (555) 123-4567", name: "Pat Placeholder"),
            (handle: "555-987-6543", name: "Lee Local"),
            (handle: "Mixed@Example.COM", name: "Mo Mail"),
        ])
        XCTAssertEqual(resolver.name(for: "+15551234567"), "Pat Placeholder")
        XCTAssertEqual(resolver.name(for: "5551234567"), "Pat Placeholder")
        XCTAssertEqual(resolver.name(for: "+15559876543"), "Lee Local")
        XCTAssertEqual(resolver.name(for: "mixed@example.com"), "Mo Mail")
        XCTAssertNil(resolver.name(for: "+15550000000"))
        XCTAssertEqual(resolver.displayName(for: "+15550000000"), "+15550000000")
    }
}
