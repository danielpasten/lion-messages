import Foundation
import MessagesModel

/// The real `MessagesService`: reads ~/Library/Messages/chat.db (read-only), resolves names via
/// Contacts, watches the database for changes and sends through Messages.app.
public final class LiveMessagesService: MessagesService {
    private let contacts: ContactResolver
    private let database: ChatDatabase
    private let sender: MessageSender
    private let watcher: DatabaseWatcher

    /// Uses the current user's `~/Library/Messages/chat.db`.
    public convenience init() {
        self.init(databasePath: ChatDatabase.defaultPath)
        // Staged copies from earlier sends are no longer needed (Messages has long since read
        // them). Only the real app does this; tests use their own outbox folders.
        let outbox = sender.outbox
        DispatchQueue.global(qos: .utility).async { outbox.cleanUp() }
    }

    /// Reads the chat.db at `databasePath` (for tests and tooling).
    public convenience init(databasePath: String) {
        self.init(databasePath: databasePath, contacts: ContactResolver(), sender: MessageSender())
    }

    init(databasePath: String, contacts: ContactResolver, sender: MessageSender,
         watcherDebounce: TimeInterval = 0.25, pollInterval: TimeInterval = 3) {
        self.contacts = contacts
        self.sender = sender
        let database = ChatDatabase(path: databasePath, contacts: contacts)
        self.database = database
        watcher = DatabaseWatcher(databasePath: databasePath, debounce: watcherDebounce,
                                  pollInterval: pollInterval) { [weak database] in database?.changeToken() }
    }

    deinit { watcher.stop() }

    public func checkAccess() async -> AccessState {
        await database.checkAccess()
    }

    public func loadConversations() async throws -> [Conversation] {
        try await database.loadConversations()
    }

    public func loadMessages(in conversation: Conversation, limit: Int) async throws -> [Message] {
        try await database.loadMessages(in: conversation, limit: limit)
    }

    public func requestContactsAccess() async -> Bool {
        await contacts.requestAccess()
    }

    public func contactImageData(forHandle handle: String?) async -> Data? {
        let contacts = self.contacts
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: contacts.imageData(for: handle))
            }
        }
    }

    public func startWatching(onChange: @escaping () -> Void) {
        watcher.start(onChange: onChange)
    }

    public func stopWatching() {
        watcher.stop()
    }

    public func send(_ text: String, to conversation: Conversation) async throws {
        try await sender.send(text, to: conversation)
    }

    public func send(attachments: [URL], text: String, to conversation: Conversation) async throws {
        try await sender.send(attachments: attachments, text: text, to: conversation)
    }
}
