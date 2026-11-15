import AppKit
import Combine
import MessagesModel
import UserNotifications

/// macOS notifications for new messages: a banner with the sender and the message, a Dock badge
/// counting what arrived while the app was in the background, and a click that opens the
/// conversation. Nothing is posted for the conversation you're reading, for your own messages,
/// for spam, or for filtered unknown senders. Never log names or message text from here.
@MainActor
final class NotificationController: NSObject, UNUserNotificationCenterDelegate {
    static let defaultsKey = "ShowNotifications"

    /// User notifications need a real app bundle; `swift run` isn't one (the framework would
    /// throw), so notifications are simply off there.
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    private(set) var isEnabled: Bool
    private weak var store: AppStore?
    private weak var window: NSWindow?
    private var cancellables: Set<AnyCancellable> = []
    /// Notifications on screen, by conversation, so opening one clears its banners.
    private var delivered: [Int64: [String]] = [:]
    private var badgeCount = 0

    init(store: AppStore, window: NSWindow, enabled: Bool) {
        self.store = store
        self.window = window
        isEnabled = enabled
        super.init()
    }

    private var center: UNUserNotificationCenter? {
        Self.isAvailable ? UNUserNotificationCenter.current() : nil
    }

    func start() {
        guard let center, let store else { return }
        center.delegate = self
        store.newIncoming
            .sink { [weak self] list in self?.post(list) }
            .store(in: &cancellables)
        store.$selectedConversationID
            .removeDuplicates()
            .sink { [weak self] id in if let id { self?.clearDelivered(for: id) } }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                self.setBadge(0)
                if let id = self.store?.selectedConversationID { self.clearDelivered(for: id) }
            }
            .store(in: &cancellables)
        if isEnabled { requestAuthorization() }
    }

    /// View ▸ Show Notifications.
    func setEnabled(_ on: Bool, persist: Bool = true) {
        if persist { UserDefaults.standard.set(on, forKey: Self.defaultsKey) }
        isEnabled = on
        if on {
            requestAuthorization()
        } else {
            center?.removeAllDeliveredNotifications()
            delivered = [:]
            setBadge(0)
        }
    }

    private func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func post(_ conversations: [Conversation]) {
        guard isEnabled, let center else { return }
        for c in conversations {
            // Already reading it: Messages stays quiet too.
            let reading = NSApp.isActive && window?.isKeyWindow == true && store?.selectedConversationID == c.id
            if reading { continue }
            let content = UNMutableNotificationContent()
            content.title = c.title
            content.body = c.lastMessagePreview == LionConstants.attachmentPlaceholder ? "Attachment" : c.lastMessagePreview
            content.sound = .default
            content.threadIdentifier = "conversation-\(c.id)"
            content.userInfo = ["conversationID": NSNumber(value: c.id)]
            let stamp = Int((c.lastMessageDate ?? Date()).timeIntervalSinceReferenceDate * 1000)
            let id = "message-\(c.id)-\(stamp)"
            delivered[c.id, default: []].append(id)
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            if !NSApp.isActive { setBadge(badgeCount + 1) }
        }
    }

    private func clearDelivered(for id: Int64) {
        guard let ids = delivered.removeValue(forKey: id), !ids.isEmpty else { return }
        center?.removeDeliveredNotifications(withIdentifiers: ids)
    }

    private func setBadge(_ n: Int) {
        badgeCount = n
        NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Banners show even while the app is in front (for conversations you aren't reading).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    /// A click opens the conversation.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = (response.notification.request.content.userInfo["conversationID"] as? NSNumber)?.int64Value
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            self.window?.makeKeyAndOrderFront(nil)
            if let id { self.store?.showConversation(id) }
            completionHandler()
        }
    }
}
