import Contacts
import Foundation

/// Resolves raw handles (phone numbers / emails) to contact names. Thread-safe.
///
/// The lookup table is built lazily on first use (off the main thread, from the database queue)
/// and rebuilt after `CNContactStoreDidChange`. It never prompts for permission except from
/// `requestAccess()`; without permission every lookup returns nil (callers fall back to the handle).
final class ContactResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var phones: [String: String] = [:]
    private var emails: [String: String] = [:]
    /// Handle key (same keys as `phones` / `emails`) → CNContact identifier, for pictures.
    private var contactIDs: [String: String] = [:]
    /// Contact identifier ("" = the Me card) → thumbnail data; NSNull-like empty Data = none.
    private var imageCache: [String: Data] = [:]
    private var needsRebuild = true
    /// Set only by `requestAccess()`. Lookups never ask TCC themselves: that call can block
    /// (e.g. while a permission prompt is up) and must not stall loading conversations.
    private var accessConfirmed = false
    /// When non-nil, the resolver uses only these entries and never touches the Contacts framework.
    private let fixedEntries: [(handle: String, name: String)]?
    private var store: CNContactStore?
    private var observer: NSObjectProtocol?

    init() {
        fixedEntries = nil
        observer = NotificationCenter.default.addObserver(
            forName: .CNContactStoreDidChange, object: nil, queue: nil
        ) { [weak self] _ in self?.invalidate() }
    }

    /// Test/demo initializer: a static lookup table, no Contacts framework access.
    init(entries: [(handle: String, name: String)]) {
        fixedEntries = entries
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Requests Contacts access if not yet determined. Returns true iff authorized.
    func requestAccess() async -> Bool {
        if fixedEntries != nil { return true }
        let granted: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                switch CNContactStore.authorizationStatus(for: .contacts) {
                case .authorized:
                    continuation.resume(returning: true)
                case .notDetermined:
                    CNContactStore().requestAccess(for: .contacts) { ok, _ in
                        continuation.resume(returning: ok)
                    }
                default:
                    continuation.resume(returning: false)
                }
            }
        }
        setAccess(granted)
        return granted
    }

    private func setAccess(_ granted: Bool) {
        lock.lock(); accessConfirmed = granted; needsRebuild = true; lock.unlock()
    }

    func invalidate() {
        lock.lock(); needsRebuild = true; lock.unlock()
    }

    /// Contact name for a handle, or nil when unknown / not permitted.
    func name(for handle: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if needsRebuild { rebuildLocked() }
        if handle.contains("@") {
            return emails[handle.lowercased()]
        }
        let digits = Self.digits(handle)
        guard !digits.isEmpty else { return nil }
        if let name = phones[digits] { return name }
        if digits.count > 10 { return phones[String(digits.suffix(10))] }
        return nil
    }

    func displayName(for handle: String) -> String { name(for: handle) ?? handle }

    /// Thumbnail picture (PNG/JPEG data) for a handle's contact, or for the Me card when
    /// `handle` is nil. Returns nil without Contacts permission or when there is no picture.
    func imageData(for handle: String?) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard fixedEntries == nil, accessConfirmed else { return nil }
        if needsRebuild { rebuildLocked() }
        let identifier: String
        if let handle {
            let key = handle.contains("@")
                ? handle.lowercased().trimmingCharacters(in: .whitespaces) : Self.digits(handle)
            guard let id = contactIDs[key] ?? (key.count > 10 ? contactIDs[String(key.suffix(10))] : nil)
            else { return nil }
            identifier = id
        } else {
            identifier = ""
        }
        if let cached = imageCache[identifier] { return cached.isEmpty ? nil : cached }
        let keys = [CNContactThumbnailImageDataKey as CNKeyDescriptor]
        let contact = identifier.isEmpty
            ? try? contactStore().unifiedMeContactWithKeys(toFetch: keys)
            : try? contactStore().unifiedContact(withIdentifier: identifier, keysToFetch: keys)
        let data = contact?.thumbnailImageData
        imageCache[identifier] = data ?? Data()
        return data
    }

    static func digits(_ s: String) -> String { String(s.unicodeScalars.filter { ("0"..."9").contains($0) }.map(Character.init)) }

    // MARK: - Building

    private func contactStore() -> CNContactStore {
        if let store { return store }
        let s = CNContactStore()
        store = s
        return s
    }

    /// Caller holds `lock`.
    private func rebuildLocked() {
        phones = [:]
        emails = [:]
        contactIDs = [:]
        imageCache = [:]
        if let fixedEntries {
            for entry in fixedEntries { add(handle: entry.handle, name: entry.name) }
            needsRebuild = false
            return
        }
        guard accessConfirmed else {
            // Stay dirty so names appear as soon as access is granted.
            return
        }
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey,
            CNContactOrganizationNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
        ].map { $0 as CNKeyDescriptor }
        let request = CNContactFetchRequest(keysToFetch: keys)
        do {
            try contactStore().enumerateContacts(with: request) { contact, _ in
                guard let name = Self.name(of: contact) else { return }
                for phone in contact.phoneNumbers { self.add(handle: phone.value.stringValue, name: name, id: contact.identifier) }
                for email in contact.emailAddresses { self.add(handle: email.value as String, name: name, id: contact.identifier) }
            }
            needsRebuild = false
        } catch {
            // Leave whatever was collected; try again on the next invalidation.
            needsRebuild = false
        }
    }

    private func add(handle: String, name: String, id: String? = nil) {
        if handle.contains("@") {
            let key = handle.lowercased().trimmingCharacters(in: .whitespaces)
            if emails[key] == nil { emails[key] = name; contactIDs[key] = id }
            return
        }
        let digits = Self.digits(handle)
        guard !digits.isEmpty else { return }
        if phones[digits] == nil { phones[digits] = name; contactIDs[digits] = id }
        if digits.count > 10 {
            let last10 = String(digits.suffix(10))
            if phones[last10] == nil { phones[last10] = name; contactIDs[last10] = id }
        }
    }

    private static func name(of contact: CNContact) -> String? {
        let full = [contact.givenName, contact.familyName]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !full.isEmpty { return full }
        let nick = contact.nickname.trimmingCharacters(in: .whitespaces)
        if !nick.isEmpty { return nick }
        let org = contact.organizationName.trimmingCharacters(in: .whitespaces)
        return org.isEmpty ? nil : org
    }
}
