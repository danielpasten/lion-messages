import AppKit
import Combine
import CryptoKit
import ImageIO
import LinkPresentation
import MessagesModel
import UniformTypeIdentifiers

// Link previews for links the user sent from this app. Messages.app stores no rich-link data
// for messages sent through AppleScript, so those links would only ever show as plain URLs.
//
// This is the app's ONLY network access. It happens only for messages the user sent
// (`isFromMe`) that have no stored preview, only while View ▸ Fetch Missing Link Previews is on,
// and it contacts only the linked site, through Apple's LinkPresentation. Results are cached in
// ~/Library/Application Support/Lion Messages/LinkPreviews. Never log URLs, titles or paths.

/// What a fetch returns: text plus raw picture data (downsampled before it is cached).
struct FetchedLinkMetadata: Sendable {
    var title: String?
    var summary: String?
    var siteName: String?
    var imageData: Data?
    var iconData: Data?
}

/// Fetches metadata for one URL. Nil means the fetch failed or found nothing.
@MainActor
protocol LinkMetadataFetching: AnyObject {
    func fetch(_ url: URL) async -> FetchedLinkMetadata?
    /// Stops any fetch in progress (the toggle was turned off).
    func cancelAll()
}

// MARK: - Live fetcher (LinkPresentation)

@MainActor
final class LiveLinkMetadataFetcher: LinkMetadataFetching {
    static let timeout: TimeInterval = 10
    private var providers: [UUID: LPMetadataProvider] = [:]

    func fetch(_ url: URL) async -> FetchedLinkMetadata? {
        // One provider per fetch, created and started on the main thread.
        let provider = LPMetadataProvider()
        provider.timeout = Self.timeout
        let id = UUID()
        providers[id] = provider
        defer { providers[id] = nil }
        let metadata: LPLinkMetadata? = await withCheckedContinuation { continuation in
            provider.startFetchingMetadata(for: url) { metadata, _ in continuation.resume(returning: metadata) }
        }
        guard let metadata else { return nil }
        let host = (metadata.url ?? url).host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
        // LPLinkMetadata keeps summary and site name private; read them only if present.
        func optionalString(_ key: String) -> String? {
            guard metadata.responds(to: NSSelectorFromString(key)) else { return nil }
            return metadata.value(forKey: key) as? String
        }
        let image = await Self.loadData(metadata.imageProvider)
        let icon = await Self.loadData(metadata.iconProvider)
        return FetchedLinkMetadata(title: metadata.title, summary: optionalString("summary"),
                                   siteName: optionalString("siteName") ?? host, imageData: image, iconData: icon)
    }

    func cancelAll() {
        providers.values.forEach { $0.cancel() }
        providers.removeAll()
    }

    private static func loadData(_ provider: NSItemProvider?) async -> Data? {
        guard let provider, provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}

// MARK: - Demo stub (never touches the network)

/// `--demo`: returns a canned preview for one demo URL after ~0.5 s, nothing for any other.
@MainActor
final class StubLinkMetadataFetcher: LinkMetadataFetching {
    static let demoURL = "https://maps.example.net/directions?to=cabin"
    private let image: URL?
    private let icon: URL?

    init(image: URL?, icon: URL?) {
        self.image = image
        self.icon = icon
    }

    func fetch(_ url: URL) async -> FetchedLinkMetadata? {
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard url.absoluteString == Self.demoURL else { return nil }
        return FetchedLinkMetadata(
            title: "Directions to Pine Hollow Cabin — 2 h 40 min",
            summary: "Via Ridge Road and the lakeside highway. Last 3 miles on a gravel road.",
            siteName: "Example Maps",
            imageData: image.flatMap { try? Data(contentsOf: $0) },
            iconData: icon.flatMap { try? Data(contentsOf: $0) })
    }

    func cancelAll() {}
}

// MARK: - Cache (memory + disk)

/// Previews by URL, kept as JSON plus picture files named by a hash of the URL. Entries are valid
/// for 30 days; the folder is kept under ~100 MB (oldest removed first). Failures are remembered
/// for 24 hours so a dead link is not fetched again and again.
@MainActor
final class LinkPreviewCache {
    nonisolated static let entryLifetime: TimeInterval = 30 * 24 * 60 * 60
    nonisolated static let failureLifetime: TimeInterval = 24 * 60 * 60
    nonisolated static let maxBytes: Int64 = 100 * 1024 * 1024

    struct Entry: Codable {
        var url: String
        var title: String?
        var summary: String?
        var siteName: String?
        var image: String?
        var icon: String?
        var fetched: Date
        var bytes: Int64
    }

    private struct Index: Codable {
        var entries: [String: Entry] = [:]
        var failures: [String: Date] = [:]
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lion Messages", isDirectory: true)
            .appendingPathComponent("LinkPreviews", isDirectory: true)
    }

    let directory: URL
    private var index = Index()
    private(set) var isLoaded = false
    private let io = DispatchQueue(label: "LionMessages.linkPreviewCache", qos: .utility)

    init(directory: URL) {
        self.directory = directory
    }

    static func key(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    /// Reads the index off the main thread, drops expired entries and missing files, prunes.
    func load() async {
        let dir = directory, indexURL = indexURL
        let loaded: Index = await withCheckedContinuation { continuation in
            io.async {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let index = (try? Data(contentsOf: indexURL)).flatMap { try? decoder.decode(Index.self, from: $0) } ?? Index()
                continuation.resume(returning: Self.pruned(index, directory: dir, now: Date()))
            }
        }
        index = loaded
        isLoaded = true
        save()
    }

    func preview(for url: URL) -> LinkPreview? {
        guard let e = index.entries[Self.key(for: url)], Date().timeIntervalSince(e.fetched) < Self.entryLifetime
        else { return nil }
        return LinkPreview(url: url, title: e.title, summary: e.summary, siteName: e.siteName,
                           imageFileURL: e.image.map { directory.appendingPathComponent($0) },
                           iconFileURL: e.icon.map { directory.appendingPathComponent($0) })
    }

    func failedRecently(_ url: URL) -> Bool {
        guard let date = index.failures[Self.key(for: url)] else { return false }
        return Date().timeIntervalSince(date) < Self.failureLifetime
    }

    func recordFailure(_ url: URL) {
        index.failures[Self.key(for: url)] = Date()
        save()
    }

    /// Downsamples and writes the pictures off the main thread, then records the entry.
    func store(_ metadata: FetchedLinkMetadata, for url: URL) async {
        let key = Self.key(for: url), dir = directory
        let files: (image: String?, icon: String?, bytes: Int64) = await withCheckedContinuation { continuation in
            io.async {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let image = metadata.imageData.flatMap { Self.writePicture($0, maxPixel: 600, name: key + "-image", in: dir) }
                let icon = metadata.iconData.flatMap { Self.writePicture($0, maxPixel: 64, name: key + "-icon", in: dir) }
                continuation.resume(returning: (image?.name, icon?.name, (image?.bytes ?? 0) + (icon?.bytes ?? 0)))
            }
        }
        index.failures[key] = nil
        index.entries[key] = Entry(url: url.absoluteString, title: metadata.title, summary: metadata.summary,
                                   siteName: metadata.siteName, image: files.image, icon: files.icon,
                                   fetched: Date(), bytes: files.bytes)
        // Keep the folder under the size cap: the oldest entries go first.
        var total = index.entries.values.reduce(0) { $0 + $1.bytes }
        var doomed: [String] = []
        for (oldKey, e) in index.entries.sorted(by: { $0.value.fetched < $1.value.fetched }) where total > Self.maxBytes {
            index.entries[oldKey] = nil
            total -= e.bytes
            doomed += [e.image, e.icon].compactMap { $0 }
        }
        if !doomed.isEmpty {
            io.async { doomed.forEach { try? FileManager.default.removeItem(at: dir.appendingPathComponent($0)) } }
        }
        save()
    }

    private func save() {
        let snapshot = index, dir = directory, indexURL = indexURL
        io.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    /// Expired or broken entries go; then the oldest until the folder fits the size cap; then
    /// any picture file no entry refers to.
    nonisolated private static func pruned(_ index: Index, directory: URL, now: Date) -> Index {
        var out = index
        let fm = FileManager.default
        out.failures = out.failures.filter { now.timeIntervalSince($0.value) < failureLifetime }
        out.entries = out.entries.filter { _, e in
            guard now.timeIntervalSince(e.fetched) < entryLifetime else { return false }
            return [e.image, e.icon].compactMap { $0 }.allSatisfy { fm.fileExists(atPath: directory.appendingPathComponent($0).path) }
        }
        var total = out.entries.values.reduce(0) { $0 + $1.bytes }
        for (key, e) in out.entries.sorted(by: { $0.value.fetched < $1.value.fetched }) where total > maxBytes {
            out.entries[key] = nil
            total -= e.bytes
        }
        let referenced = Set(out.entries.values.flatMap { [$0.image, $0.icon].compactMap { $0 } } + ["index.json"])
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where !referenced.contains(name) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
        return out
    }

    /// Writes a downsampled JPEG (PNG when the picture has transparency). Returns nil when the
    /// data is not a readable picture.
    nonisolated private static func writePicture(_ data: Data, maxPixel: Int, name: String, in dir: URL)
        -> (name: String, bytes: Int64)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let alpha = image.alphaInfo
        let opaque = alpha == .none || alpha == .noneSkipLast || alpha == .noneSkipFirst
        let type = opaque ? UTType.jpeg : UTType.png
        let file = name + (opaque ? ".jpg" : ".png")
        let url = dir.appendingPathComponent(file)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, (opaque ? [kCGImageDestinationLossyCompressionQuality: 0.85] : [:]) as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return (file, size)
    }
}

// MARK: - Service

/// Decorates messages with cached previews and fetches missing ones politely: at most two at a
/// time, one request per URL, newest messages first, a few per conversation open.
@MainActor
final class LinkPreviewService {
    static let maxConcurrent = 2
    static let perOpenLimit = 20
    static let defaultsKey = "FetchMissingLinkPreviews"

    /// Fires on the main thread when a new preview is in the cache.
    let didUpdate = PassthroughSubject<Void, Never>()
    private(set) var isEnabled: Bool
    private let fetcher: LinkMetadataFetching
    private let cache: LinkPreviewCache
    private var queue: [URL] = []
    private var inFlight: Set<String> = []

    init(fetcher: LinkMetadataFetching, cache: LinkPreviewCache, enabled: Bool) {
        self.fetcher = fetcher
        self.cache = cache
        isEnabled = enabled
        Task {
            await cache.load()
            didUpdate.send()
        }
    }

    /// True when nothing is queued or running and the cache has loaded (snapshots wait for this).
    var isIdle: Bool { cache.isLoaded && queue.isEmpty && inFlight.isEmpty }

    func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        isEnabled = on
        if !on {
            // Off means no network requests at all.
            queue.removeAll()
            inFlight.removeAll()
            fetcher.cancelAll()
        }
    }

    /// HARD RULE: previews are only ever fetched (or attached) for messages the user sent.
    /// Incoming messages are never fetched — that would ping links in spam texts and tell the
    /// sender the message was opened. Only the first http(s) link of a message without a stored
    /// preview qualifies.
    static func candidateURL(for m: Message) -> URL? {
        guard m.isFromMe, m.linkPreview == nil, m.text != LionConstants.attachmentPlaceholder else { return nil }
        return ContentBuilder.links(in: m.text).first {
            ["http", "https"].contains($0.url.scheme?.lowercased() ?? "")
        }?.url
    }

    /// Adds cached previews to qualifying messages. Never touches the network.
    func decorate(_ messages: [Message]) -> [Message] {
        messages.map { m in
            guard let url = Self.candidateURL(for: m), let preview = cache.preview(for: url) else { return m }
            var copy = m
            copy.linkPreview = preview
            return copy
        }
    }

    /// Queues fetches for the newest qualifying messages that have nothing cached.
    func request(for messages: [Message]) {
        guard isEnabled, cache.isLoaded else { return }
        var picked = 0
        for m in messages.reversed() {
            guard picked < Self.perOpenLimit else { break }
            guard let url = Self.candidateURL(for: m) else { continue }
            let key = LinkPreviewCache.key(for: url)
            guard cache.preview(for: url) == nil, !cache.failedRecently(url), !inFlight.contains(key),
                  !queue.contains(where: { LinkPreviewCache.key(for: $0) == key }) else { continue }
            queue.append(url)
            picked += 1
        }
        pump()
    }

    private func pump() {
        while isEnabled, inFlight.count < Self.maxConcurrent, !queue.isEmpty {
            let url = queue.removeFirst()
            let key = LinkPreviewCache.key(for: url)
            inFlight.insert(key)
            Task {
                let result = await fetcher.fetch(url)
                guard isEnabled, inFlight.contains(key) else { return }
                if let result, Self.isUseful(result) {
                    await cache.store(result, for: url)
                    inFlight.remove(key)
                    didUpdate.send()
                } else {
                    cache.recordFailure(url)
                    inFlight.remove(key)
                }
                pump()
            }
        }
    }

    private static func isUseful(_ m: FetchedLinkMetadata) -> Bool {
        !(m.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) || m.imageData != nil
    }
}
