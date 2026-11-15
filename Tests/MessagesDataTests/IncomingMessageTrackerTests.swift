import Foundation
import MessagesModel
import XCTest
@testable import MessagesData

final class IncomingMessageTrackerTests: XCTestCase {
    private func conversation(_ id: Int64, at seconds: TimeInterval?, fromMe: Bool = false) -> Conversation {
        Conversation(id: id, guid: "iMessage;-;\(id)", chatIdentifier: "\(id)", serviceName: "iMessage",
                     isGroup: false, participantHandles: ["\(id)"], title: "Chat \(id)", lastMessagePreview: "hi",
                     lastMessageDate: seconds.map { Date(timeIntervalSinceReferenceDate: $0) },
                     lastMessageIsFromMe: fromMe)
    }

    func testFirstLoadOnlySetsTheBaseline() {
        var tracker = IncomingMessageTracker()
        XCTAssertEqual(tracker.update(with: [conversation(1, at: 100), conversation(2, at: 50)]), [])
    }

    func testNewerIncomingMessageIsReported() {
        var tracker = IncomingMessageTracker()
        _ = tracker.update(with: [conversation(1, at: 100), conversation(2, at: 50)])
        let new = tracker.update(with: [conversation(2, at: 120), conversation(1, at: 100)])
        XCTAssertEqual(new.map(\.id), [2])
        // Reloading again without changes reports nothing.
        XCTAssertEqual(tracker.update(with: [conversation(2, at: 120), conversation(1, at: 100)]), [])
    }

    func testOwnMessagesAreNotReported() {
        var tracker = IncomingMessageTracker()
        _ = tracker.update(with: [conversation(1, at: 100)])
        XCTAssertEqual(tracker.update(with: [conversation(1, at: 130, fromMe: true)]), [])
    }

    func testNewConversationCountsOnlyWhenNewerThanEverythingSeen() {
        var tracker = IncomingMessageTracker()
        _ = tracker.update(with: [conversation(1, at: 100)])
        // A conversation that just appeared with an old message (e.g. moved out of a filter).
        XCTAssertEqual(tracker.update(with: [conversation(1, at: 100), conversation(3, at: 40)]), [])
        // Someone new writes.
        let new = tracker.update(with: [conversation(4, at: 150), conversation(1, at: 100), conversation(3, at: 40)])
        XCTAssertEqual(new.map(\.id), [4])
    }

    func testConversationsWithoutMessagesAreIgnored() {
        var tracker = IncomingMessageTracker()
        _ = tracker.update(with: [conversation(1, at: nil)])
        XCTAssertEqual(tracker.update(with: [conversation(1, at: nil)]), [])
    }

    func testResetStartsANewBaseline() {
        var tracker = IncomingMessageTracker()
        _ = tracker.update(with: [conversation(1, at: 100)])
        tracker.reset()
        XCTAssertEqual(tracker.update(with: [conversation(1, at: 200)]), [])
    }
}
