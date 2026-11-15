import Foundation
import MessagesModel

/// Reads the conversations pinned in Messages.app. Messages keeps them in its own preferences
/// (`~/Library/Preferences/com.apple.messages.pinning.plist`, synced through iCloud), under
/// `pD` ▸ `pP`: an ordered list of handles for 1:1 chats and "SERVICE;+;CHATNNN" for groups.
/// Read-only: Lion Messages never writes Messages' preferences.
enum MessagesPinning {
    static let domain = "com.apple.messages.pinning"

    /// Pin keys in Messages' order (empty when nothing is pinned or the file can't be read).
    static func pinnedKeys() -> [String] {
        let domain = domain as CFString
        // Pick up changes Messages made since the last read.
        CFPreferencesAppSynchronize(domain)
        let value = CFPreferencesCopyAppValue("pD" as CFString, domain)
        return keys(fromPinData: value as? [String: Any])
    }

    /// The pin keys in a `pD` dictionary, deduplicated, in order.
    static func keys(fromPinData data: [String: Any]?) -> [String] {
        guard let list = data?["pP"] as? [Any] else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for case let identifier as String in list {
            let key = PinKey.normalize(identifier)
            if !key.isEmpty, seen.insert(key).inserted { result.append(key) }
        }
        return result
    }
}
