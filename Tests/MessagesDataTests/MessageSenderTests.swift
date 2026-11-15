import Foundation
import MessagesModel
import XCTest
@testable import MessagesData

/// Only script generation and error mapping are tested. Nothing is ever executed against Messages.app:
/// every sender here uses a fake runner.
final class MessageSenderTests: XCTestCase {
    private let oneToOne = Conversation(
        id: 1, guid: "iMessage;-;+15550001111", chatIdentifier: "+15550001111", serviceName: "iMessage",
        isGroup: false, participantHandles: ["+15550001111"], title: "Demo", lastMessagePreview: "",
        lastMessageDate: nil, lastMessageIsFromMe: false)

    func testEscaping() {
        XCTAssertEqual(AppleScriptBuilder.escape(#"say "hi" \o/"#), #"say \"hi\" \\o/"#)
        XCTAssertEqual(AppleScriptBuilder.escape("line1\nline2"), "line1\nline2")
        XCTAssertEqual(AppleScriptBuilder.escape(#"\""#), #"\\\""#)
    }

    func testChatScript() {
        let script = AppleScriptBuilder.sendToChat(text: "He said \"ok\"\nthen left", chatGUID: "iMessage;+;chat1")
        XCTAssertEqual(script, """
            tell application "Messages" to send "He said \\"ok\\"
            then left" to chat id "iMessage;+;chat1"
            """)
    }

    func testParticipantScript() {
        let imessage = AppleScriptBuilder.sendToParticipant(text: #"a\b"#, handle: "demo@example.com", useSMS: false)
        XCTAssertEqual(imessage, """
            tell application "Messages"
            set targetService to 1st account whose service type = iMessage
            send "a\\\\b" to participant "demo@example.com" of targetService
            end tell
            """)
        let sms = AppleScriptBuilder.sendToParticipant(text: "x", handle: "+15550001111", useSMS: true)
        XCTAssertTrue(sms.contains("service type = SMS"))
    }

    func testServiceMappingAndAnyPrefixedGUID() async throws {
        XCTAssertTrue(MessageSender.usesSMSAccount("SMS"))
        XCTAssertTrue(MessageSender.usesSMSAccount("RCS"))
        XCTAssertTrue(MessageSender.usesSMSAccount("SatelliteSMS"))
        XCTAssertFalse(MessageSender.usesSMSAccount("iMessage"))
        XCTAssertFalse(MessageSender.usesSMSAccount("iMessageLite"))

        var conv = oneToOne
        conv.guid = "any;-;+15550001111"
        conv.serviceName = "RCS"
        var scripts: [String] = []
        let sender = MessageSender(runner: { script in
            scripts.append(script)
            return scripts.count == 1 ? (-1728, "Can’t get chat.") : nil
        })
        try await sender.send("hi", to: conv)
        XCTAssertTrue(scripts[0].hasSuffix(#"to chat id "any;-;+15550001111""#))
        XCTAssertTrue(scripts[1].contains("service type = SMS"))
    }

    func testRejectsEmptyText() async {
        let sender = MessageSender(runner: { _ in XCTFail("should not run"); return nil })
        do {
            try await sender.send("  \n ", to: oneToOne)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? SendError, .scriptFailed("Message is empty."))
        }
    }

    func testFallsBackToParticipantForOneToOne() async throws {
        var scripts: [String] = []
        let sender = MessageSender(runner: { script in
            scripts.append(script)
            return scripts.count == 1 ? (-1728, "Can’t get chat id.") : nil
        })
        try await sender.send("hello", to: oneToOne)
        XCTAssertEqual(scripts.count, 2)
        XCTAssertTrue(scripts[1].contains(#"participant "+15550001111""#))
    }

    func testAutomationDeniedDoesNotFallBack() async {
        var calls = 0
        let sender = MessageSender(runner: { _ in calls += 1; return (-1743, "Not authorized.") })
        do {
            try await sender.send("hello", to: oneToOne)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? SendError, .automationDenied)
        }
        XCTAssertEqual(calls, 1)
    }

    func testGroupFailureMapsToScriptFailed() async {
        var group = oneToOne
        group.isGroup = true
        var calls = 0
        let sender = MessageSender(runner: { _ in calls += 1; return (-1708, "Messages got an error.") })
        do {
            try await sender.send("hello", to: group)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? SendError, .scriptFailed("Messages got an error."))
        }
        XCTAssertEqual(calls, 1)
    }

    // MARK: - Attachments (files are synthetic, in temporary folders; nothing is executed)

    private func makeFile(_ name: String, in dir: URL, bytes: Int = 16) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    private func makeSender(outbox dir: URL, runner: @escaping MessageSender.ScriptRunner) -> MessageSender {
        MessageSender(runner: runner, outbox: AttachmentOutbox(directory: dir.appendingPathComponent("Outbox")))
    }

    /// The staged path inside `set theFile to POSIX file "…"`, unescaped.
    private func stagedPath(in script: String) -> String? {
        guard let start = script.range(of: "POSIX file \""),
              let end = script.range(of: "\"\n", range: start.upperBound..<script.endIndex) else { return nil }
        return String(script[start.upperBound..<end.lowerBound])
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    func testFileScripts() {
        XCTAssertEqual(AppleScriptBuilder.sendFileToChat(path: "/tmp/a b/photo.png", chatGUID: "iMessage;-;+15550001111"), """
            set theFile to POSIX file "/tmp/a b/photo.png"
            tell application "Messages" to send theFile to chat id "iMessage;-;+15550001111"
            """)
        XCTAssertEqual(AppleScriptBuilder.sendFileToParticipant(path: "/x.pdf", handle: "+15550001111", useSMS: true), """
            set theFile to POSIX file "/x.pdf"
            tell application "Messages"
            set targetService to 1st account whose service type = SMS
            send theFile to participant "+15550001111" of targetService
            end tell
            """)
    }

    func testFilePathEscaping() {
        let script = AppleScriptBuilder.sendFileToChat(path: #"/tmp/say "hi"\x/Café 🦁.png"#, chatGUID: "g")
        XCTAssertTrue(script.hasPrefix(#"set theFile to POSIX file "/tmp/say \"hi\"\\x/Café 🦁.png""#), script)
    }

    func testOneFileStagesCopyAndSendsIt() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = try makeFile("photo.png", in: dir)
        var scripts: [String] = []
        let sender = makeSender(outbox: dir) { scripts.append($0); return nil }
        try await sender.send(attachments: [original], text: "  ", to: oneToOne)
        XCTAssertEqual(scripts.count, 1, "blank text is not sent")
        XCTAssertTrue(scripts[0].hasSuffix(#"send theFile to chat id "iMessage;-;+15550001111""#))
        let staged = try XCTUnwrap(stagedPath(in: scripts[0]))
        XCTAssertNotEqual(staged, original.path)
        XCTAssertTrue(staged.hasPrefix(dir.appendingPathComponent("Outbox").path + "/"))
        XCTAssertEqual((staged as NSString).lastPathComponent, "photo.png", "original name kept")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: staged)), try Data(contentsOf: original))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path), "original untouched")
    }

    func testSeveralFilesThenTextInOrder() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try makeFile("a.png", in: dir)
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let b = try makeFile("a.png", in: sub) // same name: staged into separate folders
        let c = try makeFile("notes.txt", in: dir)
        var scripts: [String] = []
        let sender = makeSender(outbox: dir) { scripts.append($0); return nil }
        try await sender.send(attachments: [a, b, c], text: " Hello! \n", to: oneToOne)
        XCTAssertEqual(scripts.count, 4)
        let staged = scripts.prefix(3).compactMap(stagedPath)
        XCTAssertEqual(staged.map { ($0 as NSString).lastPathComponent }, ["a.png", "a.png", "notes.txt"])
        XCTAssertEqual(Set(staged).count, 3, "name collisions get separate folders")
        XCTAssertEqual(scripts[3], #"tell application "Messages" to send "Hello!" to chat id "iMessage;-;+15550001111""#)
    }

    func testMissingFileThrowsAndRunsNothing() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = try makeFile("ok.png", in: dir)
        let missing = dir.appendingPathComponent("gone.pdf")
        let sender = makeSender(outbox: dir) { _ in XCTFail("should not run"); return nil }
        do {
            try await sender.send(attachments: [good, missing], text: "hi", to: oneToOne)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? SendError, .scriptFailed("“gone.pdf” couldn’t be found."))
            XCTAssertFalse("\(error)".contains(dir.path), "no paths in messages")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Outbox").path), "nothing staged")
    }

    func testFolderAndOversizeAreRejected() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertThrowsError(try AttachmentOutbox.validate([folder])) {
            XCTAssertEqual($0 as? SendError, .scriptFailed("“Folder” is a folder. Only files can be sent."))
        }
        let big = dir.appendingPathComponent("big.mov")
        XCTAssertTrue(FileManager.default.createFile(atPath: big.path, contents: nil))
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(AttachmentOutbox.maxFileSize + 1)) // sparse
        try handle.close()
        XCTAssertThrowsError(try AttachmentOutbox.validate([big])) {
            XCTAssertEqual($0 as? SendError, .scriptFailed("“big.mov” is larger than 100 MB and can’t be sent."))
        }
    }

    func testFileFallsBackToParticipantAndKeepsUsingIt() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try makeFile("a.jpg", in: dir), b = try makeFile("b.jpg", in: dir)
        var scripts: [String] = []
        let sender = makeSender(outbox: dir) { script in
            scripts.append(script)
            return script.contains("chat id") ? (-1728, "Can’t get chat id.") : nil
        }
        try await sender.send(attachments: [a, b], text: "caption", to: oneToOne)
        XCTAssertEqual(scripts.count, 4, "chat id tried once, then participant for every item")
        XCTAssertTrue(scripts[0].contains("chat id"))
        XCTAssertTrue(scripts[1].contains(#"send theFile to participant "+15550001111" of targetService"#))
        XCTAssertTrue(scripts[2].contains("send theFile to participant"))
        XCTAssertTrue(scripts[3].contains(#"send "caption" to participant"#))
    }

    func testAttachmentErrorMapping() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try makeFile("a.png", in: dir), b = try makeFile("b.png", in: dir)

        var calls = 0
        let denied = makeSender(outbox: dir) { _ in calls += 1; return (-1744, "Not permitted.") }
        do {
            try await denied.send(attachments: [a], text: "", to: oneToOne)
            XCTFail("expected error")
        } catch { XCTAssertEqual(error as? SendError, .automationDenied) }
        XCTAssertEqual(calls, 1, "no fallback after a permission error")

        var group = oneToOne
        group.isGroup = true
        var n = 0
        let partial = makeSender(outbox: dir) { _ in n += 1; return n == 2 ? (-1708, "Messages got an error.") : nil }
        do {
            try await partial.send(attachments: [a, b], text: "", to: group)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? SendError, .scriptFailed("Messages got an error. 1 item was sent before the error."))
        }
    }

    func testOutboxCleanupRemovesOnlyOldItems() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outbox = AttachmentOutbox(directory: dir.appendingPathComponent("Outbox"))
        let source = try makeFile("x.png", in: dir)
        let old = try outbox.stage(source).deletingLastPathComponent()
        let fresh = try outbox.stage(source).deletingLastPathComponent()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 86_400)],
                                              ofItemAtPath: old.path)
        XCTAssertEqual(outbox.cleanUp(), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertEqual(AttachmentOutbox(directory: dir.appendingPathComponent("missing")).cleanUp(), 0)
    }
}
