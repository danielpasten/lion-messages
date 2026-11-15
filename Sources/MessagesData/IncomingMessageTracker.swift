import Foundation
import MessagesModel

/// Spots messages that arrived since the conversation list was last loaded, so the app can
/// notify about them. It compares each conversation's newest message date with the previous
/// load; the first load only sets the baseline (nothing that was already there is "new").
public struct IncomingMessageTracker {
    private var lastSeen: [Int64: Date] = [:]
    /// The newest message date seen in any conversation, so a conversation that appears for the
    /// first time only counts when its message is newer than everything loaded before.
    private var newestSeen: Date?
    private var isPrimed = false

    public init() {}

    /// Conversations whose newest message is new since the previous call and was sent by
    /// someone else, in the order given.
    public mutating func update(with conversations: [Conversation]) -> [Conversation] {
        defer {
            for c in conversations {
                guard let date = c.lastMessageDate else { continue }
                lastSeen[c.id] = max(lastSeen[c.id] ?? date, date)
                newestSeen = max(newestSeen ?? date, date)
            }
            isPrimed = true
        }
        guard isPrimed else { return [] }
        return conversations.filter { c in
            guard let date = c.lastMessageDate, !c.lastMessageIsFromMe else { return false }
            if let previous = lastSeen[c.id] { return date > previous }
            guard let newestSeen else { return true }
            return date > newestSeen
        }
    }

    /// Forgets everything (for example after access to the database was lost and regained), so
    /// the next load sets a new baseline instead of announcing old messages.
    public mutating func reset() {
        self = IncomingMessageTracker()
    }
}
