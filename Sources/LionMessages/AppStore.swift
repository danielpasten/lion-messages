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
        /// Fetched link previews were added to these messages: re-measure them in place, fade.
        case linkPreviews(Set<Int64>)
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
    /// Files waiting to be sent with the draft. Global, like the text draft.
    @Published private(set) var pendingAttachments: [PendingAttachment] = []
    @Published private(set) var isSending = false
    /// A send that includes files is running (staging large files can take a moment).
    @Published private(set) var isSendingAttachments = false
    /// Files are being dragged over the conversation area.
    @Published private(set) var isDropTargeted = false
    @Published var presentedError: PresentedError?
    /// View ▸ Show Buddy Pictures (persisted; `--buddy-pictures` overrides it for one launch).
    @Published private(set) var showBuddyPictures: Bool
    /// Fires when a buddy picture finished loading (pictures never change any row's size).
    let buddyPicturesDidLoad = PassthroughSubject<Void, Never>()

    /// Fires when the composer should take keyboard focus.
    let focusComposer = PassthroughSubject<Void, Never>()
    /// Fires when a send starts (the Send button shows its pressed state briefly).
    let didStartSend = PassthroughSubject<Void, Never>()
    /// The Attach button or File ▸ Attach Files… asks for the open panel (the app delegate owns the window).
    let attachPanelRequested = PassthroughSubject<Void, Never>()

    private let service: MessagesService
    /// Cached and fetched previews for links the user sent (see LinkPreviewFetcher.swift).
    let linkPreviews: LinkPreviewService
    private var cancellables: Set<AnyCancellable> = []
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

    init(service: MessagesService, linkPreviews: LinkPreviewService, forcePermissionScreen: Bool = false,
         initialSelectionIndex: Int = 0, buddyPicturesOverride: Bool? = nil) {
        self.service = service
        self.linkPreviews = linkPreviews
        self.forcePermissionScreen = forcePermissionScreen
        self.initialSelectionIndex = initialSelectionIndex
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Self.buddyPicturesDefaultsKey: true])
        showBuddyPictures = buddyPicturesOverride ?? defaults.bool(forKey: Self.buddyPicturesDefaultsKey)
        linkPreviews.didUpdate
            .sink { [weak self] in self?.applyFetchedPreviews() }
            .store(in: &cancellables)
    }

    // MARK: Link previews

    /// View ▸ Fetch Missing Link Previews.
    var fetchesLinkPreviews: Bool { linkPreviews.isEnabled }

    func setFetchLinkPreviews(_ on: Bool, persist: Bool = true) {
        if persist { UserDefaults.standard.set(on, forKey: LinkPreviewService.defaultsKey) }
        linkPreviews.setEnabled(on)
        objectWillChange.send()
        if on { linkPreviews.request(for: transcript.messages) }
    }

    /// A preview arrived (or the cache finished loading): attach it to the open transcript.
    private func applyFetchedPreviews() {
        let current = transcript
        guard current.conversationID != nil, !current.messages.isEmpty else { return }
        let decorated = linkPreviews.decorate(current.messages)
        let changed = Set(zip(current.messages, decorated).filter { $0 != $1 }.map(\.1.id))
        guard !changed.isEmpty else {
            linkPreviews.request(for: current.messages)
            return
        }
        let generation = messageLoadGeneration
        Task {
            await MediaGeometry.prewarm(decorated)
            guard generation == messageLoadGeneration, transcript.conversationID == current.conversationID,
                  transcript.messages.map(\.id) == current.messages.map(\.id) else { return }
            transcript = TranscriptState(conversationID: current.conversationID, isGroup: current.isGroup,
                                         messages: linkPreviews.decorate(transcript.messages), reason: .linkPreviews(changed))
            linkPreviews.request(for: transcript.messages)
        }
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
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty)
    }

    // MARK: Attachments

    /// Files can be added while a conversation is open and no sheet is up.
    var canAcceptAttachments: Bool {
        accessState == .granted && selectedConversation != nil && presentedError == nil
    }

    /// Adds files as pending attachments (duplicates and folders are skipped). Returns whether
    /// anything was accepted.
    @discardableResult
    func addAttachments(_ urls: [URL]) -> Bool {
        guard canAcceptAttachments else { return false }
        var known = Set(pendingAttachments.map { $0.url.standardizedFileURL.path })
        var added: [PendingAttachment] = []
        for url in urls where url.isFileURL {
            let path = url.standardizedFileURL.path
            var isDirectory: ObjCBool = false
            guard !known.contains(path), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            known.insert(path)
            added.append(PendingAttachment(url: url.standardizedFileURL))
        }
        guard !added.isEmpty else { return false }
        pendingAttachments += added
        return true
    }

    func removeAttachment(_ id: PendingAttachment.ID) {
        pendingAttachments.removeAll { $0.id == id }
        focusComposer.send()
    }

    func requestAttachPanel() {
        guard canAcceptAttachments else { return }
        attachPanelRequested.send()
    }

    func setDropTargeted(_ on: Bool) {
        if isDropTargeted != on { isDropTargeted = on }
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
        let loaded = (try? await service.loadMessages(in: conversation, limit: Self.messageLimit)) ?? []
        let messages = linkPreviews.decorate(loaded)
        // Picture/video sizes come from file headers, read off the main thread before the
        // transcript measures its rows.
        await MediaGeometry.prewarm(messages)
        guard generation == messageLoadGeneration, selectedConversationID == conversation.id else { return }
        transcript = TranscriptState(conversationID: conversation.id, isGroup: conversation.isGroup,
                                     messages: messages, reason: reason)
        linkPreviews.request(for: messages)
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
        let originalAttachments = pendingAttachments
        let text = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !originalAttachments.isEmpty, !isSending,
              let conversation = selectedConversation else { return }
        didStartSend.send()
        draft = ""
        pendingAttachments = []
        isSending = true
        isSendingAttachments = !originalAttachments.isEmpty
        Task {
            do {
                if originalAttachments.isEmpty {
                    try await service.send(text, to: conversation)
                } else {
                    try await service.send(attachments: originalAttachments.map(\.url), text: text, to: conversation)
                }
                isSending = false
                isSendingAttachments = false
                if selectedConversationID == conversation.id {
                    await loadMessages(reason: .sent)
                }
            } catch {
                isSending = false
                isSendingAttachments = false
                if draft.isEmpty { draft = original }
                if pendingAttachments.isEmpty { pendingAttachments = originalAttachments }
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
