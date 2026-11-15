import Foundation
import MessagesModel

/// Turns Messages' tapback rows into the reactions currently on each message.
///
/// A tapback is its own row in `message`: `associated_message_type` 2000–2006 adds one (love,
/// like, dislike, laugh, emphasize, question, emoji in `associated_message_emoji`), 3000–3006
/// removes it, and `associated_message_guid` names the target ("p:0/GUID" for part 0 of GUID,
/// "bp:GUID" for older rows). Each person has at most one tapback per message: a new one
/// replaces theirs. Sticker reactions (2007) aren't shown.
enum ReactionResolver {
    struct Row {
        var targetGUID: String?
        var type: Int64
        var emoji: String?
        var isFromMe: Bool
        var handle: String?
        var senderName: String?
    }

    /// The message GUID inside an `associated_message_guid`.
    static func messageGUID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let slash = trimmed.firstIndex(of: "/") { return String(trimmed[trimmed.index(after: slash)...]) }
        if trimmed.hasPrefix("bp:") { return String(trimmed.dropFirst(3)) }
        return trimmed
    }

    static func kind(type: Int64, emoji: String?) -> Reaction.Kind? {
        switch type {
        case 2000: return .love
        case 2001: return .like
        case 2002: return .dislike
        case 2003: return .laugh
        case 2004: return .emphasize
        case 2005: return .question
        case 2006:
            guard let e = emoji?.trimmingCharacters(in: .whitespacesAndNewlines), !e.isEmpty else { return nil }
            return .emoji(e)
        default: return nil
        }
    }

    /// `rows` oldest first. Returns reactions per target message GUID, oldest first.
    static func resolve(_ rows: [Row]) -> [String: [Reaction]] {
        struct Key: Hashable { let target: String; let sender: String }
        var current: [Key: (reaction: Reaction, type: Int64, order: Int)] = [:]
        for (n, row) in rows.enumerated() {
            guard let raw = row.targetGUID, let target = messageGUID(raw) else { continue }
            let key = Key(target: target, sender: row.isFromMe ? "\u{0}me" : (row.handle ?? "\u{0}unknown"))
            switch row.type {
            case 2000...2006:
                guard let kind = kind(type: row.type, emoji: row.emoji) else { continue }
                current[key] = (Reaction(kind: kind, isFromMe: row.isFromMe,
                                         senderHandle: row.isFromMe ? nil : row.handle,
                                         senderName: row.isFromMe ? nil : row.senderName), row.type, n)
            case 3000...3006:
                if let existing = current[key], existing.type == row.type - 1000 { current[key] = nil }
            default:
                continue
            }
        }
        var result: [String: [(Reaction, Int)]] = [:]
        for (key, value) in current { result[key.target, default: []].append((value.reaction, value.order)) }
        return result.mapValues { $0.sorted { $0.1 < $1.1 }.map(\.0) }
    }
}
