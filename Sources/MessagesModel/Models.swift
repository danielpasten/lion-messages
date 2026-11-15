import Foundation

// The contract between the data layer (MessagesData) and the UI (LionMessages).

/// One row in the sidebar. `id` is chat.ROWID.
public struct Conversation: Identifiable, Hashable, Sendable {
    public var id: Int64
    /// chat.guid, e.g. "iMessage;-;+15551234567" or "any;-;..." — used for sending.
    public var guid: String
    /// chat.chat_identifier: a phone/email for 1:1 chats, "chatNNN" for groups.
    public var chatIdentifier: String
    /// "iMessage", "SMS", "RCS", ...
    public var serviceName: String
    public var isGroup: Bool
    /// Raw handles (phone numbers / emails) of the other participants.
    public var participantHandles: [String]
    /// Already resolved for display: group name, contact name(s), or raw handle.
    public var title: String
    /// Plain-text preview of the last message ("[Attachment]" when it has no text).
    public var lastMessagePreview: String
    public var lastMessageDate: Date?
    public var lastMessageIsFromMe: Bool
    /// Which of Messages' sender lists the conversation belongs to.
    public var senderCategory: SenderCategory

    public init(id: Int64, guid: String, chatIdentifier: String, serviceName: String,
                isGroup: Bool, participantHandles: [String], title: String,
                lastMessagePreview: String, lastMessageDate: Date?, lastMessageIsFromMe: Bool,
                senderCategory: SenderCategory = .known) {
        self.id = id; self.guid = guid; self.chatIdentifier = chatIdentifier
        self.serviceName = serviceName; self.isGroup = isGroup
        self.participantHandles = participantHandles; self.title = title
        self.lastMessagePreview = lastMessagePreview; self.lastMessageDate = lastMessageDate
        self.lastMessageIsFromMe = lastMessageIsFromMe; self.senderCategory = senderCategory
    }

    /// The key Messages uses to pin this conversation: the chat identifier (a phone number or
    /// email for 1:1 chats, "chatNNN" for groups), lowercased. See `PinKey`.
    public var pinKey: String { PinKey.normalize(chatIdentifier) }
}

/// Messages' sender filtering ("Filter Unknown Senders"), as recorded in chat.db.
public enum SenderCategory: String, Hashable, Sendable, CaseIterable {
    /// A contact, someone you've replied to, or any chat Messages didn't filter.
    case known
    /// Filtered by Messages as an unknown sender, and you haven't replied.
    case unknown
    /// Reported or detected as junk/spam (or from a blocked sender).
    case spam
}

/// Matches Messages' pin identifiers (from the `com.apple.messages.pinning` preferences) to
/// conversations. Messages stores a handle ("+15551234567", "name@example.com") for 1:1 chats
/// and "SERVICE;+;CHATNNN" for groups; both reduce to the chat identifier, lowercased.
public enum PinKey {
    public static func normalize(_ identifier: String) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = trimmed.split(separator: ";", omittingEmptySubsequences: false).last.map(String.init) ?? trimmed
        return last.lowercased()
    }
}

/// One message bubble. `id` is message.ROWID.
public struct Message: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var guid: String
    /// Display text. Never empty: "[Attachment]" when the message has only attachments.
    public var text: String
    public var isFromMe: Bool
    public var date: Date
    /// Raw handle of the sender (nil when isFromMe).
    public var senderHandle: String?
    /// Resolved sender name for group chats (contact name or raw handle; nil when isFromMe).
    public var senderName: String?
    public var serviceName: String
    public var hasAttachment: Bool
    /// Visible attachments in display order (hidden plugin payloads such as link-preview images
    /// are excluded). Empty when the message has none or they could not be read.
    public var attachments: [MessageAttachment]
    /// Rich link preview stored by Messages for URL balloons (no network involved).
    public var linkPreview: LinkPreview?
    /// Tapbacks currently on the message (at most one per person), oldest first.
    public var reactions: [Reaction]

    public init(id: Int64, guid: String, text: String, isFromMe: Bool, date: Date,
                senderHandle: String?, senderName: String?, serviceName: String, hasAttachment: Bool,
                attachments: [MessageAttachment] = [], linkPreview: LinkPreview? = nil, reactions: [Reaction] = []) {
        self.id = id; self.guid = guid; self.text = text; self.isFromMe = isFromMe
        self.date = date; self.senderHandle = senderHandle; self.senderName = senderName
        self.serviceName = serviceName; self.hasAttachment = hasAttachment
        self.attachments = attachments; self.linkPreview = linkPreview; self.reactions = reactions
    }
}

/// A tapback on a message.
public struct Reaction: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case love, like, dislike, laugh, emphasize, question
        /// Any emoji (iOS 18 / macOS 15 and later).
        case emoji(String)

        /// What the badge shows.
        public var symbol: String {
            switch self {
            case .love: return "❤️"
            case .like: return "👍"
            case .dislike: return "👎"
            case .laugh: return "😂"
            case .emphasize: return "‼️"
            case .question: return "❓"
            case .emoji(let e): return e
            }
        }

        /// "Loved", "Liked"… for tooltips and VoiceOver.
        public var verb: String {
            switch self {
            case .love: return "Loved"
            case .like: return "Liked"
            case .dislike: return "Disliked"
            case .laugh: return "Laughed at"
            case .emphasize: return "Emphasized"
            case .question: return "Questioned"
            case .emoji(let e): return "Reacted \(e) to"
            }
        }
    }

    public var kind: Kind
    public var isFromMe: Bool
    /// Raw handle of whoever reacted (nil when isFromMe).
    public var senderHandle: String?
    /// Contact name or raw handle of whoever reacted (nil when isFromMe).
    public var senderName: String?

    public init(kind: Kind, isFromMe: Bool, senderHandle: String?, senderName: String?) {
        self.kind = kind; self.isFromMe = isFromMe
        self.senderHandle = senderHandle; self.senderName = senderName
    }
}

/// One visible file attached to a message. `id` is attachment.ROWID.
public struct MessageAttachment: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case image, video, audio, other
    }

    public var id: Int64
    /// Derived from the MIME type, else the UTI, else the file extension.
    public var kind: Kind
    /// Absolute local file URL (`~` expanded). Nil when the row has no filename or the file is
    /// not on disk (e.g. offloaded to iCloud). Existence is checked when messages are loaded.
    public var fileURL: URL?
    public var mimeType: String?
    public var uti: String?
    /// The original file name (transfer_name), else the last path component of the stored path.
    public var displayName: String?
    /// Size in bytes as recorded by Messages; nil when unknown (NULL, 0 or column missing).
    public var byteCount: Int64?
    public var isSticker: Bool

    public init(id: Int64, kind: Kind, fileURL: URL?, mimeType: String?, uti: String?,
                displayName: String?, byteCount: Int64?, isSticker: Bool) {
        self.id = id; self.kind = kind; self.fileURL = fileURL; self.mimeType = mimeType
        self.uti = uti; self.displayName = displayName; self.byteCount = byteCount
        self.isSticker = isSticker
    }
}

/// Link preview metadata Messages already stored with a URL balloon message.
public struct LinkPreview: Hashable, Sendable {
    /// The link as shared (originalURL), else the resolved/canonical URL.
    public var url: URL
    public var title: String?
    public var summary: String?
    public var siteName: String?
    /// Local preview image file; nil unless it exists on disk.
    public var imageFileURL: URL?
    /// Local site icon file; nil unless it exists on disk.
    public var iconFileURL: URL?

    public init(url: URL, title: String? = nil, summary: String? = nil, siteName: String? = nil,
                imageFileURL: URL? = nil, iconFileURL: URL? = nil) {
        self.url = url; self.title = title; self.summary = summary; self.siteName = siteName
        self.imageFileURL = imageFileURL; self.iconFileURL = iconFileURL
    }
}

/// Whether we can read ~/Library/Messages/chat.db.
public enum AccessState: Equatable, Sendable {
    case granted
    /// The file exists (or its folder does) but the OS refused: Full Disk Access is missing.
    case fullDiskAccessDenied
    /// No chat.db at all (Messages never used on this Mac).
    case databaseMissing
    case failed(String)
}

public enum SendError: Error, Equatable, Sendable {
    /// macOS Automation permission for controlling Messages.app was denied (errAEEventNotPermitted, -1743).
    case automationDenied
    /// Any other AppleScript failure; the string is safe to show to the user.
    case scriptFailed(String)
}

/// Everything the UI needs. Implemented by `LiveMessagesService` (MessagesData) and by a demo
/// service with fake data in the app target. All methods may be called from the main actor;
/// implementations do their heavy work off the main thread.
public protocol MessagesService: AnyObject {
    /// Cheap probe: can chat.db be opened read-only right now?
    func checkAccess() async -> AccessState

    /// Conversations sorted by most recent message first.
    func loadConversations() async throws -> [Conversation]

    /// The most recent `limit` messages of a conversation, oldest first.
    func loadMessages(in conversation: Conversation, limit: Int) async throws -> [Message]

    /// Asks for Contacts permission if not yet decided. Returns whether names can be resolved.
    /// Safe to call repeatedly. After it returns true, reload conversations to pick up names.
    func requestContactsAccess() async -> Bool

    /// Start watching chat.db / chat.db-wal. `onChange` is called on the main queue
    /// (debounced) whenever the database changes. Calling again replaces the handler.
    func startWatching(onChange: @escaping () -> Void)
    func stopWatching()

    /// Sends `text` to the conversation via Messages.app. Throws `SendError`.
    func send(_ text: String, to conversation: Conversation) async throws

    /// Sends local files, then `text` (when it isn't blank), to the conversation via Messages.app,
    /// in that order. Throws `SendError`. Has a default implementation that only handles text, so
    /// other conformers keep compiling; it is a requirement so the live implementation is reached
    /// through the protocol.
    func send(attachments: [URL], text: String, to conversation: Conversation) async throws

    /// Contact picture (encoded image data) for a handle, or the user's own picture when
    /// `handle` is nil. Nil when there is no picture or Contacts access is missing.
    /// Has a default implementation returning nil.
    func contactImageData(forHandle handle: String?) async -> Data?

    /// The conversations pinned in Messages, as pin keys (`PinKey.normalize`) in Messages' order.
    /// Has a default implementation returning none.
    func pinnedConversationKeys() async -> [String]
}

public extension MessagesService {
    func contactImageData(forHandle handle: String?) async -> Data? { nil }

    func pinnedConversationKeys() async -> [String] { [] }

    func send(attachments: [URL], text: String, to conversation: Conversation) async throws {
        guard attachments.isEmpty else {
            throw SendError.scriptFailed("Sending files isn’t supported here.")
        }
        try await send(text, to: conversation)
    }
}

public enum LionConstants {
    public static let attachmentPlaceholder = "[Attachment]"
    public static let fullDiskAccessSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    public static let automationSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
}
