import AppKit
import Combine
import ImageIO
import MessagesModel

/// What the transcript should show, plus why it changed (drives scrolling).
struct TranscriptState: Equatable {
    enum Reason: Equatable {
        /// A different conversation was opened: jump to the bottom.
        case opened
        /// The database changed: keep the reader's position unless they were at the bottom.
        case refreshed
        /// The user just sent something: scroll to the bottom.
        case sent
    }

    var conversationID: Int64?
    var isGroup: Bool
    var messages: [Message]
    var reason: Reason

    static let empty = TranscriptState(conversationID: nil, isGroup: false, messages: [], reason: .opened)
}

/// A send failure waiting to be shown in a sheet.
struct PresentedError: Identifiable, Equatable {
    let id = UUID()
    let error: SendError
}

@MainActor
final class AppStore: ObservableObject {
    static let messageLimit = 300

    /// nil while the first access check is running.
    @Published private(set) var accessState: AccessState?
    @Published private(set) var conversations: [Conversation] = []
    @Published private(set) var filteredConversations: [Conversation] = []
    @Published var searchText = "" { didSet { if searchText != oldValue { applyFilter() } } }
    @Published private(set) var selectedConversationID: Int64?
    @Published private(set) var transcript = TranscriptState.empty
    @Published var draft = ""
    @Published private(set) var isSending = false
    @Published var presentedError: PresentedError?
    /// View ▸ Show Buddy Pictures (persisted; `--buddy-pictures` overrides it for one launch).
    @Published private(set) var showBuddyPictures: Bool
    /// Fires when a buddy picture finished loading (pictures never change any row's size).
    let buddyPicturesDidLoad = PassthroughSubject<Void, Never>()

    /// Fires when the composer should take keyboard focus.
    let focusComposer = PassthroughSubject<Void, Never>()
    /// Fires when a send starts (the Send button shows its pressed state briefly).
    let didStartSend = PassthroughSubject<Void, Never>()

    private let service: MessagesService
    private let forcePermissionScreen: Bool
    private let initialSelectionIndex: Int
    private var pollTimer: Timer?
    private var activeObserver: NSObjectProtocol?
    private var didBootstrap = false
    private var isChecking = false
    private var refreshInFlight = false
    private var refreshPending = false
    private var messageLoadGeneration = 0

    static let buddyPicturesDefaultsKey = "ShowBuddyPictures"
    /// Contact pictures by key ("me" or a handle), downsampled for 32 pt.
    private var buddyPictures: [String: NSImage] = [:]
    /// Keys asked for (fetched once each until contacts access changes), with their handles.
    private var buddyPictureRequests: [String: String?] = [:]
    private var buddyPictureFetching: Set<String> = []

    init(service: MessagesService, forcePermissionScreen: Bool = false, initialSelectionIndex: Int = 0,
         buddyPicturesOverride: Bool? = nil) {
        self.service = service
        self.forcePermissionScreen = forcePermissionScreen
        self.initialSelectionIndex = initialSelectionIndex
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Self.buddyPicturesDefaultsKey: true])
        showBuddyPictures = buddyPicturesOverride ?? defaults.bool(forKey: Self.buddyPicturesDefaultsKey)
    }

    // MARK: Buddy pictures

    func setShowBuddyPictures(_ on: Bool, persist: Bool = true) {
        if persist { UserDefaults.standard.set(on, forKey: Self.buddyPicturesDefaultsKey) }
        if on != showBuddyPictures { showBuddyPictures = on }
    }

    /// True while any contact picture is still being fetched (snapshots wait for it).
    var isLoadingBuddyPictures: Bool { !buddyPictureFetching.isEmpty }

    /// The picture for a sender (nil handle + `isFromMe` = the user's own "Me" card), or nil when
    /// there is none (yet). The first request for a sender fetches it in the background.
    func buddyPicture(isFromMe: Bool, handle: String?) -> NSImage? {
        let key: String
        if isFromMe { key = "me" } else if let handle { key = "h:" + handle } else { return nil }
        if buddyPictureRequests[key] == nil {
            buddyPictureRequests[key] = .some(isFromMe ? nil : handle)
            fetchBuddyPicture(key: key, handle: isFromMe ? nil : handle)
        }
        return buddyPictures[key]
    }

    private func fetchBuddyPicture(key: String, handle: String?) {
        guard !buddyPictureFetching.contains(key) else { return }
        buddyPictureFetching.insert(key)
        Task {
            let data = await service.contactImageData(forHandle: handle)
            let image = await Self.decodeBuddyPicture(data)
            buddyPictureFetching.remove(key)
            if buddyPictures[key] !== image {
                buddyPictures[key] = image
                buddyPicturesDidLoad.send()
            }
        }
    }

    /// Re-fetches every picture asked for so far (e.g. after Contacts access was granted).
    private func refreshBuddyPictures() {
        for (key, handle) in buddyPictureRequests { fetchBuddyPicture(key: key, handle: handle) }
    }

    /// Downsamples contact image data (often a large photo) off the main thread.
    nonisolated private static func decodeBuddyPicture(_ data: Data?) async -> NSImage? {
        guard let data else { return nil }
        let cg: CGImage? = await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 128,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
        return cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
    }

    var selectedConversation: Conversation? {
        guard let id = selectedConversationID else { return nil }
        return conversations.first { $0.id == id }
    }

    var canSend: Bool {
        !isSending && selectedConversation != nil
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Access

    func start() {
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.accessState != .granted, !self.forcePermissionScreen else { return }
                await self.checkAccess()
            }
        }
        if forcePermissionScreen {
            accessState = .fullDiskAccessDenied
            return
        }
        Task { await checkAccess() }
    }

    /// "Check Again" on the permission screen.
    func checkAgain() {
        Task { await checkAccess() }
    }

    private func checkAccess() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        let state = await service.checkAccess()
        if state == .granted {
            stopPolling()
            accessState = .granted
            await bootstrap()
        } else {
            accessState = state
            if !forcePermissionScreen { startPolling() }
        }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkAccess() }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        await reloadConversations()
        if selectedConversationID == nil, !conversations.isEmpty {
            let index = min(max(initialSelectionIndex, 0), conversations.count - 1)
            select(conversations[index].id)
        }
        service.startWatching { [weak self] in
            Task { @MainActor in self?.databaseDidChange() }
        }
        if await service.requestContactsAccess() {
            await reloadConversations()
            refreshBuddyPictures()
        }
    }

    // MARK: Loading

    private func reloadConversations() async {
        do {
            let list = try await service.loadConversations()
            conversations = list
            applyFilter()
            if let id = selectedConversationID, !list.contains(where: { $0.id == id }) {
                select(list.first?.id)
            }
        } catch {
            // The database may have become unreadable (e.g. access revoked).
            let state = await service.checkAccess()
            if state != .granted {
                accessState = state
                didBootstrap = false
                service.stopWatching()
                startPolling()
            }
        }
    }

    private func loadMessages(reason: TranscriptState.Reason) async {
        guard let conversation = selectedConversation else {
            transcript = .empty
            return
        }
        messageLoadGeneration += 1
        let generation = messageLoadGeneration
        let messages = (try? await service.loadMessages(in: conversation, limit: Self.messageLimit)) ?? []
        // Picture/video sizes come from file headers, read off the main thread before the
        // transcript measures its rows.
        await MediaGeometry.prewarm(messages)
        guard generation == messageLoadGeneration, selectedConversationID == conversation.id else { return }
        transcript = TranscriptState(conversationID: conversation.id, isGroup: conversation.isGroup,
                                     messages: messages, reason: reason)
    }

    private func databaseDidChange() {
        guard accessState == .granted else { return }
        if refreshInFlight {
            refreshPending = true
            return
        }
        refreshInFlight = true
        Task {
            await reloadConversations()
            await loadMessages(reason: .refreshed)
            refreshInFlight = false
            if refreshPending {
                refreshPending = false
                databaseDidChange()
            }
        }
    }

    /// Toolbar refresh button / Cmd-R.
    func refresh() { databaseDidChange() }

    private func applyFilter() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            filteredConversations = conversations
        } else {
            filteredConversations = conversations.filter { c in
                c.title.localizedCaseInsensitiveContains(query)
                    || c.lastMessagePreview.localizedCaseInsensitiveContains(query)
                    || c.participantHandles.contains { $0.localizedCaseInsensitiveContains(query) }
            }
        }
    }

    // MARK: Selection

    func select(_ id: Int64?) {
        guard id != selectedConversationID else { return }
        selectedConversationID = id
        transcript = TranscriptState(conversationID: id, isGroup: selectedConversation?.isGroup ?? false,
                                     messages: [], reason: .opened)
        Task { await loadMessages(reason: .opened) }
    }

    // MARK: Sending

    func sendDraft() {
        let original = draft
        let text = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending, let conversation = selectedConversation else { return }
        didStartSend.send()
        draft = ""
        isSending = true
        Task {
            do {
                try await service.send(text, to: conversation)
                isSending = false
                if selectedConversationID == conversation.id {
                    await loadMessages(reason: .sent)
                }
            } catch {
                isSending = false
                if draft.isEmpty { draft = original }
                let sendError = (error as? SendError) ?? .scriptFailed(error.localizedDescription)
                presentedError = PresentedError(error: sendError)
            }
            focusComposer.send()
        }
    }

    /// Return pressed while the error sheet is up: same as its default button.
    func confirmError() {
        if presentedError?.error == .automationDenied {
            NSWorkspace.shared.open(LionConstants.automationSettingsURL)
        }
        dismissError()
    }

    func dismissError() {
        presentedError = nil
        focusComposer.send()
    }
}
