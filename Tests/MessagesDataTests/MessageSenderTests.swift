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
}
