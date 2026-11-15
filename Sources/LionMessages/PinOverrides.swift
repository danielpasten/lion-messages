import Foundation

/// Pins and unpins made in Lion Messages, layered over the pins Messages keeps (which this app
/// only reads). Keys are `PinKey`s. Persisted in the app's own preferences, or kept in memory
/// (the demo) when there's no `defaults`.
final class PinOverrides {
    static let defaultsKey = "PinOverrides"

    /// Pinned here, in the order they were pinned (shown after Messages' pins).
    private(set) var added: [String]
    /// Pinned in Messages but unpinned here.
    private(set) var removed: Set<String>
    private let defaults: UserDefaults?

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        let stored = defaults?.dictionary(forKey: Self.defaultsKey)
        added = stored?["added"] as? [String] ?? []
        removed = Set(stored?["removed"] as? [String] ?? [])
    }

    func effective(messagesKeys: [String]) -> [String] {
        let fromMessages = messagesKeys.filter { !removed.contains($0) }
        let known = Set(fromMessages)
        return fromMessages + added.filter { !known.contains($0) }
    }

    func pin(_ key: String, messagesKeys: [String]) {
        removed.remove(key)
        if !messagesKeys.contains(key), !added.contains(key) { added.append(key) }
        save()
    }

    func unpin(_ key: String, messagesKeys: [String]) {
        added.removeAll { $0 == key }
        if messagesKeys.contains(key) { removed.insert(key) }
        save()
    }

    private func save() {
        defaults?.set(["added": added, "removed": removed.sorted()], forKey: Self.defaultsKey)
    }
}
