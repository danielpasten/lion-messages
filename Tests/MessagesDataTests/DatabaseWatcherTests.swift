import Foundation
import XCTest
@testable import MessagesData

final class DatabaseWatcherTests: XCTestCase {
    private var dir: URL!
    private var writer: FixtureDB!

    override func setUpWithError() throws {
        dir = try makeTempDirectory()
        writer = try FixtureDB(path: dir.appendingPathComponent("chat.db").path)
        writer.exec("PRAGMA journal_mode = WAL;")
        writer.exec(FixtureDB.fullSchema)
        writer.exec("""
            INSERT INTO handle (ROWID, id, service) VALUES (1, '+15550002222', 'iMessage');
            INSERT INTO chat (ROWID, guid, style, chat_identifier, service_name) VALUES
                (1, 'iMessage;-;+15550002222', 45, '+15550002222', 'iMessage');
            INSERT INTO chat_handle_join VALUES (1, 1);
            INSERT INTO message (ROWID, guid, text, handle_id, date) VALUES (1, 'G1', 'first', 1, 1000);
            INSERT INTO chat_message_join VALUES (1, 1, 1000);
            """)
    }

    override func tearDownWithError() throws {
        writer.close()
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeService(poll: TimeInterval = 3) -> LiveMessagesService {
        LiveMessagesService(databasePath: writer.path, contacts: ContactResolver(entries: []),
                            sender: MessageSender(runner: { _ in nil }), watcherDebounce: 0.2, pollInterval: poll)
    }

    private func insert(_ id: Int, _ text: String) {
        writer.run("INSERT INTO message (ROWID, guid, text, handle_id, date) VALUES (?, ?, ?, 1, ?)",
                   [id, "G\(id)", text, 1000 + id])
        writer.run("INSERT INTO chat_message_join VALUES (1, ?, ?)", [id, 1000 + id])
    }

    func testFiresOnWALWriteAndSeesNewRows() throws {
        let service = makeService()
        let fired = expectation(description: "onChange")
        fired.assertForOverFulfill = false
        service.startWatching { fired.fulfill() }
        defer { service.stopWatching() }

        // Let the sources arm, then write through the separate read-write connection.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        insert(2, "second")
        wait(for: [fired], timeout: 5)

        // The read-only connection must see the committed WAL content.
        let loaded = expectation(description: "load")
        Task {
            let convs = try? await service.loadConversations()
            XCTAssertEqual(convs?.first?.lastMessagePreview, "second")
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 5)
    }

    func testPollFallbackDetectsChanges() throws {
        // A path with no file or folder means no vnode sources: only the poll can notice changes.
        let lock = NSLock()
        var token = 0
        let watcher = DatabaseWatcher(databasePath: dir.appendingPathComponent("missing/chat.db").path,
                                      debounce: 0.1, pollInterval: 0.3) {
            lock.lock(); defer { lock.unlock() }
            return "\(token)"
        }
        let fired = expectation(description: "poll")
        fired.assertForOverFulfill = false
        watcher.start { fired.fulfill() }
        defer { watcher.stop() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        lock.lock(); token += 1; lock.unlock()
        wait(for: [fired], timeout: 3)
    }

    func testStopPreventsCallbacks() throws {
        let service = makeService(poll: 0.3)
        let notFired = expectation(description: "no callback")
        notFired.isInverted = true
        service.startWatching { notFired.fulfill() }
        service.stopWatching()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        insert(4, "fourth")
        wait(for: [notFired], timeout: 1.5)
    }
}
