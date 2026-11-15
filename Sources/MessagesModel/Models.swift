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

    public init(id: Int64, guid: String, chatIdentifier: String, serviceName: String,
                isGroup: Bool, participantHandles: [String], title: String,
                lastMessagePreview: String, lastMessageDate: Date?, lastMessageIsFromMe: Bool) {
        self.id = id; self.guid = guid; self.chatIdentifier = chatIdentifier
        self.serviceName = serviceName; self.isGroup = isGroup
        self.participantHandles = participantHandles; self.title = title
        self.lastMessagePreview = lastMessagePreview; self.lastMessageDate = lastMessageDate
        self.lastMessageIsFromMe = lastMessageIsFromMe
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

    public init(id: Int64, guid: String, text: String, isFromMe: Bool, date: Date,
                senderHandle: String?, senderName: String?, serviceName: String, hasAttachment: Bool,
                attachments: [MessageAttachment] = [], linkPreview: LinkPreview? = nil) {
        self.id = id; self.guid = guid; self.text = text; self.isFromMe = isFromMe
        self.date = date; self.senderHandle = senderHandle; self.senderName = senderName
        self.serviceName = serviceName; self.hasAttachment = hasAttachment
        self.attachments = attachments; self.linkPreview = linkPreview
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
}

public extension MessagesService {
    func contactImageData(forHandle handle: String?) async -> Data? { nil }

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
