import Foundation
import MessagesModel
import XCTest
@testable import MessagesData

/// Attachments and link previews against synthetic chat.db fixtures. All data is fake; files are
/// created only in a temp directory.
final class AttachmentTests: XCTestCase {
    private var dir: URL!
    private var dbPath: String!
    private let base: Int64 = 700_000_000
    private func ns(_ offset: Int64) -> Int64 { (base + offset) * 1_000_000_000 }

    override func setUpWithError() throws {
        dir = try makeTempDirectory()
        dbPath = dir.appendingPathComponent("chat.db").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeService(path: String) -> LiveMessagesService {
        LiveMessagesService(databasePath: path, contacts: ContactResolver(entries: []),
                            sender: MessageSender(runner: { _ in XCTFail("must not send"); return nil }))
    }

    private func file(_ name: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try Data("fake".utf8).write(to: url)
        return url.path
    }

    private func conversation(_ service: LiveMessagesService, id: Int64) async throws -> Conversation {
        let convs = try await service.loadConversations()
        return try XCTUnwrap(convs.first { $0.id == id })
    }

    private func conv1(_ service: LiveMessagesService) async throws -> Conversation {
        try await conversation(service, id: 1)
    }

    private static let currentSchemaExtras = """
        ALTER TABLE attachment ADD COLUMN uti TEXT;
        ALTER TABLE attachment ADD COLUMN mime_type TEXT;
        ALTER TABLE attachment ADD COLUMN transfer_state INTEGER DEFAULT 0;
        ALTER TABLE attachment ADD COLUMN transfer_name TEXT;
        ALTER TABLE attachment ADD COLUMN total_bytes INTEGER DEFAULT 0;
        ALTER TABLE attachment ADD COLUMN is_sticker INTEGER DEFAULT 0;
        ALTER TABLE attachment ADD COLUMN hide_attachment INTEGER DEFAULT 0;
        ALTER TABLE message ADD COLUMN balloon_bundle_id TEXT;
        ALTER TABLE message ADD COLUMN payload_data BLOB;
        INSERT INTO handle (ROWID, id, service) VALUES (1, '+15551230001', 'iMessage');
        INSERT INTO chat (ROWID, guid, style, chat_identifier, service_name) VALUES
            (1, 'iMessage;-;+15551230001', 45, '+15551230001', 'iMessage');
        INSERT INTO chat_handle_join VALUES (1, 1);
        """

    private func addMessage(_ fx: FixtureDB, id: Int64, chat: Int64 = 1, text: String?, date: Int64,
                            attachments: Bool, balloon: String? = nil, payload: Data? = nil) {
        fx.run("""
            INSERT INTO message (ROWID, guid, text, handle_id, service, date, cache_has_attachments,
                balloon_bundle_id, payload_data) VALUES (?, ?, ?, 1, 'iMessage', ?, ?, ?, ?)
            """, [id, "MSG-\(id)", text, date, attachments ? 1 : 0, balloon, payload])
        fx.run("INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (?, ?, ?)", [chat, id, date])
    }

    private func addAttachment(_ fx: FixtureDB, id: Int64, message: Int64, filename: String?, uti: String? = nil,
                               mime: String? = nil, transferName: String? = nil, bytes: Int64? = nil,
                               sticker: Bool = false, hidden: Bool = false) {
        fx.run("""
            INSERT INTO attachment (ROWID, guid, filename, uti, mime_type, transfer_name, total_bytes, is_sticker, hide_attachment)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [id, "ATT-\(id)", filename, uti, mime, transferName, bytes, sticker ? 1 : 0, hidden ? 1 : 0])
        fx.run("INSERT INTO message_attachment_join (message_id, attachment_id) VALUES (?, ?)", [message, id])
    }

    func testAttachmentsKindsFilesOrderAndLinkPreviews() async throws {
        let existingImage = try file("IMG_0001.heic")
        let iconFile = try file("icon.pluginPayloadAttachment")
        let previewImage = try file("image.pluginPayloadAttachment")
        let missing = dir.appendingPathComponent("gone.jpeg").path
        let urlBalloon = LinkPreviewDecoder.urlBalloonBundleID

        let fx = try FixtureDB(path: dbPath)
        fx.exec(FixtureDB.fullSchema)
        fx.exec(Self.currentSchemaExtras)

        // Message 1: several visible attachments plus one hidden; join order differs from ROWID order.
        addMessage(fx, id: 1, text: "\u{FFFC}\u{FFFC}\u{FFFC}\u{FFFC}\u{FFFC}\u{FFFC}", date: ns(1), attachments: true)
        addAttachment(fx, id: 7, message: 1, filename: existingImage, uti: "public.heic", mime: "image/heic",
                      transferName: "IMG_0001.HEIC", bytes: 12345)
        addAttachment(fx, id: 3, message: 1, filename: missing, uti: "public.jpeg", mime: "image/jpeg", bytes: 0)
        addAttachment(fx, id: 5, message: 1, filename: nil, uti: "com.apple.quicktime-movie", mime: "video/quicktime",
                      transferName: "clip.mov")
        addAttachment(fx, id: 9, message: 1, filename: try file("doc.pdf"), uti: "com.adobe.pdf", mime: "application/pdf")
        addAttachment(fx, id: 4, message: 1, filename: try file("sticker.heic"), uti: "public.heic", mime: "image/heic",
                      sticker: true)
        addAttachment(fx, id: 6, message: 1, filename: try file("hidden.pluginPayloadAttachment"),
                      uti: "dyn.ah62d4rv4gu8yc6durvwwaznwmuuha6xu", hidden: true)
        // Message 2: URL balloon with icon (index 0) and image (index 1) hidden attachments.
        addMessage(fx, id: 2, text: "https://example.com/story?id=1", date: ns(2), attachments: true,
                   balloon: urlBalloon, payload: richLinkPayload(sampleMetadata(imageIndex: 1, iconIndex: 0)))
        addAttachment(fx, id: 20, message: 2, filename: iconFile, uti: "dyn.x", hidden: true)
        addAttachment(fx, id: 21, message: 2, filename: previewImage, uti: "dyn.x", hidden: true)
        // Message 3: URL balloon whose image file is missing and icon index is out of range.
        addMessage(fx, id: 3, text: "https://example.com/story?id=1", date: ns(3), attachments: true,
                   balloon: urlBalloon, payload: richLinkPayload(sampleMetadata(imageIndex: 0, iconIndex: 7)))
        addAttachment(fx, id: 30, message: 3, filename: dir.appendingPathComponent("offloaded").path, hidden: true)
        // Message 4: another balloon type with a payload -> no link preview.
        addMessage(fx, id: 4, text: "game", date: ns(4), attachments: false,
                   balloon: "com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:com.example.game",
                   payload: richLinkPayload(sampleMetadata()))
        // Message 5: URL balloon with garbage payload -> nil preview, message still shown.
        addMessage(fx, id: 5, text: "https://example.com", date: ns(5), attachments: false,
                   balloon: urlBalloon, payload: Data(repeating: 1, count: 40))
        // Message 6: kinds from UTI only and from extension only.
        addMessage(fx, id: 6, text: nil, date: ns(6), attachments: true)
        addAttachment(fx, id: 60, message: 6, filename: try file("Audio Message.caf"), uti: "com.apple.coreaudio-format")
        addAttachment(fx, id: 61, message: 6, filename: try file("movie.mp4"))
        addAttachment(fx, id: 62, message: 6, filename: try file("contact.vcf"), mime: "text/vcard")
        fx.close()

        let service = makeService(path: dbPath)
        let messages = try await service.loadMessages(in: conv1(service), limit: 50)
        XCTAssertEqual(messages.map(\.id), [1, 2, 3, 4, 5, 6])

        // Text rules unchanged.
        XCTAssertEqual(messages[0].text, LionConstants.attachmentPlaceholder)
        XCTAssertTrue(messages[0].hasAttachment)
        XCTAssertEqual(messages[5].text, LionConstants.attachmentPlaceholder)

        let a = messages[0].attachments
        XCTAssertEqual(a.map(\.id), [7, 3, 5, 9, 4], "join order, hidden excluded")
        XCTAssertEqual(a.map(\.kind), [.image, .image, .video, .other, .image])
        XCTAssertEqual(a[0].fileURL, URL(fileURLWithPath: existingImage))
        XCTAssertEqual(a[0].fileURL?.isFileURL, true)
        XCTAssertEqual(a[0].displayName, "IMG_0001.HEIC")
        XCTAssertEqual(a[0].byteCount, 12345)
        XCTAssertEqual(a[0].mimeType, "image/heic")
        XCTAssertEqual(a[0].uti, "public.heic")
        XCTAssertFalse(a[0].isSticker)
        XCTAssertNil(a[1].fileURL, "missing on disk")
        XCTAssertEqual(a[1].displayName, "gone.jpeg")
        XCTAssertNil(a[1].byteCount, "0 bytes means unknown")
        XCTAssertNil(a[2].fileURL, "NULL filename")
        XCTAssertEqual(a[2].displayName, "clip.mov")
        XCTAssertNotNil(a[3].fileURL)
        XCTAssertTrue(a[4].isSticker)

        let preview = try XCTUnwrap(messages[1].linkPreview)
        XCTAssertEqual(messages[1].attachments, [], "plugin payload attachments are hidden")
        XCTAssertEqual(messages[1].text, "https://example.com/story?id=1")
        XCTAssertEqual(preview.url, URL(string: "https://example.com/story?id=1"))
        XCTAssertEqual(preview.title, "Example Story")
        XCTAssertEqual(preview.summary, "A synthetic summary.")
        XCTAssertEqual(preview.siteName, "Example")
        XCTAssertEqual(preview.imageFileURL, URL(fileURLWithPath: previewImage))
        XCTAssertEqual(preview.iconFileURL, URL(fileURLWithPath: iconFile))

        let preview3 = try XCTUnwrap(messages[2].linkPreview)
        XCTAssertNil(preview3.imageFileURL)
        XCTAssertNil(preview3.iconFileURL)
        XCTAssertNil(messages[3].linkPreview)
        XCTAssertNil(messages[4].linkPreview)
        XCTAssertEqual(messages[4].text, "https://example.com")

        XCTAssertEqual(messages[5].attachments.map(\.kind), [.audio, .video, .other])
        XCTAssertNil(messages[0].linkPreview)

        // Conversation preview unchanged ("[Attachment]" rules).
        let conv = try await conversation(service, id: 1)
        XCTAssertEqual(conv.lastMessagePreview, LionConstants.attachmentPlaceholder)
    }

    func testManyMessagesAreChunked() async throws {
        let fx = try FixtureDB(path: dbPath)
        fx.exec(FixtureDB.fullSchema)
        fx.exec(Self.currentSchemaExtras)
        fx.exec("BEGIN")
        let count = ChatDatabase.attachmentChunkSize * 2 + 37
        for i in 1...count {
            let id = Int64(i)
            addMessage(fx, id: id, text: nil, date: ns(id), attachments: true)
            addAttachment(fx, id: id * 10, message: id, filename: "/nonexistent/\(i).png", mime: "image/png")
            addAttachment(fx, id: id * 10 + 1, message: id, filename: nil, mime: "video/mp4")
        }
        fx.exec("COMMIT")
        fx.close()

        let service = makeService(path: dbPath)
        let messages = try await service.loadMessages(in: conv1(service), limit: count)
        XCTAssertEqual(messages.count, count)
        XCTAssertTrue(messages.allSatisfy { $0.attachments.map(\.id) == [$0.id * 10, $0.id * 10 + 1] })
        XCTAssertTrue(messages.allSatisfy { $0.attachments.map(\.kind) == [.image, .video] })
    }

    func testOlderSchemaWithoutOptionalAttachmentColumns() async throws {
        let jpg = try file("photo.jpg")
        let fx = try FixtureDB(path: dbPath)
        fx.exec("""
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT, service TEXT);
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, style INTEGER, chat_identifier TEXT, service_name TEXT);
            CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, handle_id INTEGER,
                service TEXT, date INTEGER, is_from_me INTEGER);
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY, guid TEXT, filename TEXT);
            CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER,
                PRIMARY KEY (message_id, attachment_id)) WITHOUT ROWID;
            INSERT INTO handle VALUES (1, 'someone@example.com', 'iMessage');
            INSERT INTO chat VALUES (1, 'iMessage;-;someone@example.com', 45, 'someone@example.com', 'iMessage');
            INSERT INTO chat_handle_join VALUES (1, 1);
            INSERT INTO message VALUES (1, 'A', 'look', 1, 'iMessage', 400000000, 0), (2, 'B', 'plain', 0, 'iMessage', 400000100, 1);
            INSERT INTO chat_message_join VALUES (1, 1), (1, 2);
            INSERT INTO message_attachment_join VALUES (1, 12), (1, 11);
            """)
        fx.run("INSERT INTO attachment VALUES (11, 'G11', ?), (12, 'G12', NULL)", [jpg])
        fx.close()

        let service = makeService(path: dbPath)
        let messages = try await service.loadMessages(in: conv1(service), limit: 10)
        XCTAssertEqual(messages.map(\.text), ["look", "plain"])
        let a = messages[0].attachments
        XCTAssertEqual(a.map(\.id), [11, 12], "falls back to attachment ROWID order")
        XCTAssertEqual(a[0].kind, .image, "from extension")
        XCTAssertEqual(a[0].fileURL, URL(fileURLWithPath: jpg))
        XCTAssertEqual(a[0].displayName, "photo.jpg")
        XCTAssertNil(a[0].byteCount)
        XCTAssertNil(a[0].mimeType)
        XCTAssertFalse(a[0].isSticker)
        XCTAssertEqual(a[1].kind, .other)
        XCTAssertNil(a[1].fileURL)
        XCTAssertNil(a[1].displayName)
        XCTAssertTrue(messages.allSatisfy { $0.linkPreview == nil })
        XCTAssertEqual(messages[1].attachments, [])
    }

    func testTildeExpansionUsesRealHome() {
        let home = ChatDatabase.homeDirectory
        XCTAssertEqual(ChatDatabase.expandedPath("~/Library/Messages/Attachments/ab/01/X/a.jpg"),
                       home + "/Library/Messages/Attachments/ab/01/X/a.jpg")
        XCTAssertEqual(ChatDatabase.expandedPath("/var/folders/x/y.png"), "/var/folders/x/y.png")
        XCTAssertNil(ChatDatabase.expandedPath("  "))
    }

    func testKindClassification() {
        XCTAssertEqual(AttachmentKind.kind(mimeType: "image/heic-sequence", uti: nil, path: nil), .image)
        XCTAssertEqual(AttachmentKind.kind(mimeType: "VIDEO/MP4", uti: nil, path: nil), .video)
        XCTAssertEqual(AttachmentKind.kind(mimeType: "audio/x-m4a", uti: nil, path: nil), .audio)
        XCTAssertEqual(AttachmentKind.kind(mimeType: "text/x-vlocation", uti: "public.vlocation", path: "a.loc.vcf"), .other)
        XCTAssertEqual(AttachmentKind.kind(mimeType: nil, uti: "com.compuserve.gif", path: nil), .image)
        XCTAssertEqual(AttachmentKind.kind(mimeType: nil, uti: "com.apple.quicktime-movie", path: nil), .video)
        XCTAssertEqual(AttachmentKind.kind(mimeType: nil, uti: "dyn.ah62d4rv4gu8y", path: "x.pluginPayloadAttachment"), .other)
        XCTAssertEqual(AttachmentKind.kind(mimeType: nil, uti: nil, path: "/a/b/IMG.PNG"), .image)
        XCTAssertEqual(AttachmentKind.kind(mimeType: nil, uti: nil, path: nil), .other)
    }
}
