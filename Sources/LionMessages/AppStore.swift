import AppKit
import Combine
import ImageIO
import MessagesData
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

/// Which of Messages' sender lists the sidebar shows (the scope bar above the list).
enum SidebarScope: String, CaseIterable, Hashable {
    /// Known senders, or every non-spam conversation when unknown senders aren't filtered.
    case known
    case unknown
    case spam

    func includes(_ category: SenderCategory, filteringUnknown: Bool) -> Bool {
        switch self {
        case .known: return category == .known || (!filteringUnknown && category == .unknown)
        case .unknown: return filteringUnknown && category == .unknown
        case .spam: return category == .spam
        }
    }

    /// Scope bar label.
    func label(filteringUnknown: Bool) -> String {
        switch self {
        case .known: return filteringUnknown ? "Known Senders" : "All Messages"
        case .unknown: return "Unknown Senders"
        case .spam: return "Spam"
        }
    }

    /// Source-list header above the rows.
    func header(filteringUnknown: Bool) -> String {
        switch self {
        case .known: return filteringUnknown ? "KNOWN SENDERS" : "CONVERSATIONS"
        case .unknown: return "UNKNOWN SENDERS"
        case .spam: return "SPAM"
        }
    }

    static func scopes(filteringUnknown: Bool) -> [SidebarScope] {
        filteringUnknown ? [.known, .unknown, .spam] : [.known, .spam]
    }
}

/// A FaceTime call waiting for the user to confirm it in a sheet.
struct PendingCall: Identifiable, Equatable {
    enum Kind: Equatable { case audio, video }

    let id = UUID()
    let kind: Kind
    let conversation: Conversation

    /// The URL that hands the call to FaceTime (it opens its own call window).
    var url: URL? {
        guard let handle = conversation.participantHandles.first,
              let encoded = handle.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) else { return nil }
        return URL(string: (kind == .video ? "facetime://" : "facetime-audio://") + encoded)
    }
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
    @Published private(set) var transcript = TranscriptState.empty {
        // Quick Look shows the open conversation's media: close it when another one opens.
        didSet { if transcript.conversationID != oldValue.conversationID { QuickLookCoordinator.shared.close() } }
    }
    @Published var draft = ""
    /// Files waiting to be sent with the draft. Global, like the text draft.
    @Published private(set) var pendingAttachments: [PendingAttachment] = []
    @Published private(set) var isSending = false
    /// A send that includes files is running (staging large files can take a moment).
    @Published private(set) var isSendingAttachments = false
    /// Files are being dragged over the conversation area.
    @Published private(set) var isDropTargeted = false
    @Published var presentedError: PresentedError?
    /// A call waiting to be confirmed (the call sheet is up).
    @Published private(set) var pendingCall: PendingCall?
    /// The sender list the sidebar shows.
    @Published private(set) var scope: SidebarScope = .known
    /// Fires with conversations that just received a message worth a notification (not from the
    /// user, not spam, and not a filtered unknown sender).
    let newIncoming = PassthroughSubject<[Conversation], Never>()

    /// Set for a conversation popped out into its own window: this store shows only that
    /// conversation, has no list, and gets database changes from the main window's store.
    let popOutConversationID: Int64?
    var isPopOut: Bool { popOutConversationID != nil }
    /// Stores of popped-out windows, told about every database change.
    private let followers = NSHashTable<AppStore>.weakObjects()
    /// Double-click / Open in New Window: the app delegate opens (or brings forward) the window.
    let popOutRequested = PassthroughSubject<Int64, Never>()

    /// View ▸ Hide Conversations (persisted): the list is folded away even in a wide window.
    @Published private(set) var sidebarHiddenByUser: Bool
    /// The window is too narrow for the list beside the transcript, so it folds away.
    @Published private(set) var isNarrow = false
    /// In a narrow window, the list slid in over the transcript for a moment.
    @Published private(set) var sidebarOverlay = false
    static let hideSidebarDefaultsKey = "HideConversationList"
    /// Narrower than this, the transcript keeps the window to itself.
    static let narrowWidth: CGFloat = 640
    private var incomingTracker = IncomingMessageTracker()
    /// View ▸ Filter Unknown Senders (persisted): unknown senders get their own list.
    @Published private(set) var filtersUnknownSenders: Bool
    /// Pinned conversations, in pin order, for the grid at the top of the sidebar. Empty while
    /// searching and outside the main list (they're listed as rows then).
    @Published private(set) var pinnedConversations: [Conversation] = []
    /// Conversations in each sender list (for the scope bar).
    @Published private(set) var scopeCounts: [SidebarScope: Int] = [:]
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
    /// Pins from Messages, plus the pins and unpins made here.
    private var messagesPinKeys: [String] = []
    private let pinOverrides: PinOverrides
    /// False in the demo: the call sheet works, but nothing is handed to FaceTime.
    private let placesCalls: Bool
    static let filterUnknownDefaultsKey = "FilterUnknownSenders"

    static let buddyPicturesDefaultsKey = "ShowBuddyPictures"
    /// Contact pictures by key ("me" or a handle), downsampled for 32 pt.
    private var buddyPictures: [String: NSImage] = [:]
    /// Keys asked for (fetched once each until contacts access changes), with their handles.
    private var buddyPictureRequests: [String: String?] = [:]
    private var buddyPictureFetching: Set<String> = []

    init(service: MessagesService, linkPreviews: LinkPreviewService, pinOverrides: PinOverrides,
         placesCalls: Bool = true, forcePermissionScreen: Bool = false,
         initialSelectionIndex: Int = 0, buddyPicturesOverride: Bool? = nil,
         filterUnknownOverride: Bool? = nil, initialScope: SidebarScope = .known,
         popOutConversationID: Int64? = nil) {
        self.popOutConversationID = popOutConversationID
        self.service = service
        self.linkPreviews = linkPreviews
        self.pinOverrides = pinOverrides
        self.placesCalls = placesCalls
        self.forcePermissionScreen = forcePermissionScreen
        self.initialSelectionIndex = initialSelectionIndex
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Self.buddyPicturesDefaultsKey: true, Self.filterUnknownDefaultsKey: true])
        showBuddyPictures = buddyPicturesOverride ?? defaults.bool(forKey: Self.buddyPicturesDefaultsKey)
        sidebarHiddenByUser = defaults.bool(forKey: Self.hideSidebarDefaultsKey)
        let filtering = filterUnknownOverride ?? defaults.bool(forKey: Self.filterUnknownDefaultsKey)
        filtersUnknownSenders = filtering
        scope = SidebarScope.scopes(filteringUnknown: filtering).contains(initialScope) ? initialScope : .known
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

    // MARK: Quick Look

    /// Shows an attachment in the Quick Look panel, with every other picture and video of the
    /// conversation a ← → away (oldest first). A sticker is shown on its own.
    func quickLook(attachmentID: Int64) {
        var items: [QuickLookCoordinator.Item] = []
        var clicked: QuickLookCoordinator.Item?
        for m in transcript.messages {
            for a in m.attachments {
                guard let url = a.fileURL, a.kind == .image || a.kind == .video else { continue }
                let item = QuickLookCoordinator.Item(id: a.id, url: url)
                if a.id == attachmentID { clicked = item }
                if !(a.isSticker && a.kind == .image) { items.append(item) }
            }
        }
        guard let clicked else { return }
        if !items.contains(clicked) { items = [clicked] }
        QuickLookCoordinator.shared.preview(items, current: clicked)
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
        accessState == .granted && selectedConversation != nil && presentedError == nil && pendingCall == nil
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
                guard let self, !self.forcePermissionScreen else { return }
                if self.accessState == .granted {
                    // Pins may have changed in Messages (they don't touch chat.db).
                    await self.reloadPins()
                } else {
                    await self.checkAccess()
                }
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
        if let id = popOutConversationID {
            // A popped-out window: just its conversation. The main store watches the database
            // and has already asked for Contacts.
            select(id)
            return
        }
        let visible = visibleConversations
        if selectedConversationID == nil, !visible.isEmpty {
            let index = min(max(initialSelectionIndex, 0), visible.count - 1)
            select(visible[index].id)
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
            messagesPinKeys = await service.pinnedConversationKeys()
            conversations = list
            // Only the main window's store announces new messages (pop-outs see the same ones).
            let fresh = isPopOut ? [] : incomingTracker.update(with: list).filter { c in
                switch c.senderCategory {
                case .known: return true
                case .unknown: return !filtersUnknownSenders
                case .spam: return false
                }
            }
            if !fresh.isEmpty { newIncoming.send(fresh) }
            applyFilter()
            if !isPopOut, let id = selectedConversationID, !list.contains(where: { $0.id == id }) {
                select(list.first?.id)
            }
        } catch {
            // The database may have become unreadable (e.g. access revoked).
            let state = await service.checkAccess()
            if state != .granted {
                accessState = state
                incomingTracker.reset()
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
        for follower in followers.allObjects { follower.followDatabaseChange() }
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

    private func reloadPins() async {
        let keys = await service.pinnedConversationKeys()
        guard keys != messagesPinKeys else { return }
        messagesPinKeys = keys
        applyFilter()
    }

    /// Splits the conversations into the pinned grid and the rows of the current sender list.
    private func applyFilter() {
        let filtering = filtersUnknownSenders
        var counts: [SidebarScope: Int] = [:]
        for c in conversations {
            for s in SidebarScope.allCases where s.includes(c.senderCategory, filteringUnknown: filtering) {
                counts[s, default: 0] += 1
            }
        }
        if counts != scopeCounts { scopeCounts = counts }

        // Pinned conversations (never spam) show as a grid on the main list, and leave the rows.
        var pinned: [Conversation] = []
        var pinnedIDs = Set<Int64>()
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if scope == .known, query.isEmpty {
            let candidates = conversations.filter { $0.senderCategory != .spam }
            for key in pinnedKeys {
                // The newest chat with that identifier (conversations are newest first).
                if let c = candidates.first(where: { $0.pinKey == key }), pinnedIDs.insert(c.id).inserted {
                    pinned.append(c)
                }
            }
        }
        if pinned != pinnedConversations { pinnedConversations = pinned }

        filteredConversations = conversations.filter { c in
            guard !pinnedIDs.contains(c.id) else { return false }
            if query.isEmpty {
                // Pinned unknown senders show with the pins, not in the unknown list.
                if scope == .unknown, pinnedKeys.contains(c.pinKey) { return false }
                return scope.includes(c.senderCategory, filteringUnknown: filtering)
            }
            return scope.includes(c.senderCategory, filteringUnknown: filtering)
                && (c.title.localizedCaseInsensitiveContains(query)
                    || c.lastMessagePreview.localizedCaseInsensitiveContains(query)
                    || c.participantHandles.contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }

    /// Everything in the sidebar, top to bottom: pins (row by row), then the list.
    var visibleConversations: [Conversation] { pinnedConversations + filteredConversations }

    // MARK: Sender lists

    func setScope(_ newScope: SidebarScope) {
        guard newScope != scope, SidebarScope.scopes(filteringUnknown: filtersUnknownSenders).contains(newScope) else { return }
        scope = newScope
        applyFilter()
        selectFirstIfHidden()
    }

    /// Opens a conversation from outside the sidebar (a notification): switches to the list it
    /// is in and clears the search so it can be seen.
    func showConversation(_ id: Int64) {
        guard let c = conversations.first(where: { $0.id == id }) else { return }
        let target: SidebarScope
        switch c.senderCategory {
        case .spam: target = .spam
        case .unknown: target = filtersUnknownSenders ? .unknown : .known
        case .known: target = .known
        }
        if !searchText.isEmpty { searchText = "" }
        setScope(target)
        select(id)
    }

    func setFiltersUnknownSenders(_ on: Bool, persist: Bool = true) {
        if persist { UserDefaults.standard.set(on, forKey: Self.filterUnknownDefaultsKey) }
        guard on != filtersUnknownSenders else { return }
        filtersUnknownSenders = on
        if !SidebarScope.scopes(filteringUnknown: on).contains(scope) { scope = .known }
        applyFilter()
        selectFirstIfHidden()
    }

    /// After switching lists: open the first conversation if the open one isn't in this list.
    private func selectFirstIfHidden() {
        guard !isPopOut else { return }
        let visible = visibleConversations
        guard !visible.contains(where: { $0.id == selectedConversationID }) else { return }
        select(visible.first?.id)
    }

    // MARK: Pins

    /// Messages' pins minus those unpinned here, then those pinned here.
    private var pinnedKeys: [String] { pinOverrides.effective(messagesKeys: messagesPinKeys) }

    func isPinned(_ conversation: Conversation) -> Bool { pinnedKeys.contains(conversation.pinKey) }

    func setPinned(_ pinned: Bool, _ conversation: Conversation) {
        guard conversation.senderCategory != .spam || !pinned else { return }
        if pinned {
            pinOverrides.pin(conversation.pinKey, messagesKeys: messagesPinKeys)
        } else {
            pinOverrides.unpin(conversation.pinKey, messagesKeys: messagesPinKeys)
        }
        objectWillChange.send()
        applyFilter()
    }

    // MARK: Calls

    /// FaceTime can be started with the open conversation (one person; groups aren't supported).
    var canCall: Bool {
        guard let c = selectedConversation, !c.isGroup, c.participantHandles.first != nil else { return false }
        return accessState == .granted && presentedError == nil && pendingCall == nil
    }

    /// The call buttons and Conversation menu: confirm in a sheet first, so a stray click
    /// never rings anyone.
    func requestCall(_ kind: PendingCall.Kind) {
        guard canCall, let conversation = selectedConversation else { return }
        pendingCall = PendingCall(kind: kind, conversation: conversation)
    }

    func confirmCall() {
        guard let call = pendingCall else { return }
        pendingCall = nil
        if placesCalls, let url = call.url { NSWorkspace.shared.open(url) }
        focusComposer.send()
    }

    func cancelCall() {
        pendingCall = nil
        focusComposer.send()
    }

    // MARK: Selection

    // MARK: Conversation list

    /// The list sits beside the transcript (wide window, not hidden by the user).
    var sidebarDocked: Bool { !isPopOut && !sidebarHiddenByUser && !isNarrow }

    /// Opens a conversation in its own window.
    func popOut(_ id: Int64) {
        popOutRequested.send(id)
    }

    /// A popped-out window's store follows this one's database changes.
    func addFollower(_ store: AppStore) {
        followers.add(store)
    }

    /// The main store saw the database change.
    fileprivate func followDatabaseChange() {
        databaseDidChange()
    }

    /// The toolbar button and View ▸ Show/Hide Conversations: in a narrow window the list slides
    /// in over the transcript; otherwise it is folded away or brought back beside it.
    func toggleSidebar() {
        guard !isPopOut else { return }
        if isNarrow {
            sidebarOverlay.toggle()
        } else {
            sidebarHiddenByUser.toggle()
            UserDefaults.standard.set(sidebarHiddenByUser, forKey: Self.hideSidebarDefaultsKey)
            sidebarOverlay = false
        }
    }

    func dismissSidebarOverlay() {
        if sidebarOverlay { sidebarOverlay = false }
    }

    /// Called as the window resizes.
    func setWindowWidth(_ width: CGFloat) {
        let narrow = width < Self.narrowWidth
        guard narrow != isNarrow else { return }
        isNarrow = narrow
        if !narrow { sidebarOverlay = false }
    }

    func select(_ id: Int64?) {
        guard id != selectedConversationID else { dismissSidebarOverlay(); return }
        dismissSidebarOverlay()
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
