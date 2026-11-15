import AppKit
import AVFoundation
import ImageIO
import MessagesModel
import QuickLookThumbnailing
import Quartz

// Local media for the transcript: cheap header-only sizes (so rows measure right before any
// pixels exist), off-main downsampled decoding into a bounded cache, and video thumbnails.
// Only local files handed over by the model are ever read; nothing touches the network.
// Never log paths, URLs, names or message text from here.

/// A tiny lock-protected dictionary, safe to use from any thread.
final class LockedDictionary<Key: Hashable, Value>: @unchecked Sendable {
    private var storage: [Key: Value] = [:]
    private let lock = NSLock()

    subscript(key: Key) -> Value? {
        get { lock.lock(); defer { lock.unlock() }; return storage[key] }
        set { lock.lock(); storage[key] = newValue; lock.unlock() }
    }
}

/// Pixel dimensions of local pictures and videos, as they will be displayed (EXIF orientation
/// applied). Reads only file headers; results are cached for the life of the app.
enum MediaGeometry {
    /// `.zero` marks a file that could not be read as an image.
    private static let imageSizes = LockedDictionary<String, CGSize>()
    private static let videoSizes = LockedDictionary<String, CGSize>()

    /// Display-oriented pixel size, or nil when the file isn't a readable image.
    /// Reads the header synchronously on a cache miss (normally pre-warmed off the main thread).
    static func pixelSize(of url: URL) -> CGSize? {
        let key = url.path
        let size = imageSizes[key] ?? {
            let s = readImageHeader(url)
            imageSizes[key] = s
            return s
        }()
        return size == .zero ? nil : size
    }

    /// Natural (rotation-applied) video size if it has been pre-warmed; nil otherwise.
    static func videoSize(of url: URL) -> CGSize? {
        guard let s = videoSizes[url.path], s != .zero else { return nil }
        return s
    }

    private static func readImageHeader(_ url: URL) -> CGSize {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              w > 0, h > 0 else { return .zero }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// Reads every header the transcript will need, off the main thread, before the messages are
    /// shown, so measuring rows never waits on disk.
    static func prewarm(_ messages: [Message]) async {
        var images: [URL] = []
        var videos: [URL] = []
        for m in messages {
            for a in m.attachments {
                guard let url = a.fileURL else { continue }
                switch a.kind {
                case .image: if imageSizes[url.path] == nil { images.append(url) }
                case .video: if videoSizes[url.path] == nil { videos.append(url) }
                default: break
                }
            }
            if let url = m.linkPreview?.imageFileURL, imageSizes[url.path] == nil { images.append(url) }
        }
        guard !images.isEmpty || !videos.isEmpty else { return }
        await Task.detached(priority: .userInitiated) {
            for url in images { _ = pixelSize(of: url) }
            for url in videos { videoSizes[url.path] = await readVideoSize(url) }
        }.value
    }

    private static func readVideoSize(_ url: URL) async -> CGSize {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let loaded = try? await track.load(.naturalSize, .preferredTransform) else { return .zero }
        let r = CGRect(origin: .zero, size: loaded.0).applying(loaded.1)
        let s = CGSize(width: abs(r.width), height: abs(r.height))
        return s.width > 0 && s.height > 0 ? s : .zero
    }
}

/// Downsampled pictures for the transcript, decoded off the main thread and cached by
/// (identity, pixel size). Never holds full-resolution images.
@MainActor
final class MediaLoader {
    static let shared = MediaLoader()

    enum Kind { case image, videoThumbnail }

    struct Request: Hashable {
        /// Attachment id ("a123") or link-preview identity ("p123"), plus the file.
        let id: String
        let url: URL
        let kind: Kind
        /// Longest side of the decoded bitmap, in pixels.
        let maxPixel: Int

        var cacheKey: String { "\(id)|\(kind == .image ? "i" : "v")|\(maxPixel)" }
    }

    /// Cancels interest in a pending load (the view was reused or went away).
    struct Token: Hashable {
        fileprivate let key: String
        fileprivate let waiter: UUID
    }

    private final class InFlight {
        var operation: Operation?
        var waiters: [UUID: (CGImage) -> Void] = [:]
    }

    private let cache = NSCache<NSString, CGImage>()
    private var inFlight: [String: InFlight] = [:]
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "LionMessages.media"
        q.maxConcurrentOperationCount = 3
        q.qualityOfService = .userInitiated
        return q
    }()

    private init() {
        cache.totalCostLimit = 96 * 1024 * 1024
        cache.countLimit = 400
    }

    /// True when no decode is running or waiting (snapshots wait for this).
    var isIdle: Bool { inFlight.isEmpty }

    func cached(_ request: Request) -> CGImage? { cache.object(forKey: request.cacheKey as NSString) }

    /// Starts (or joins) a load. `completion` runs on the main thread unless cancelled first.
    func load(_ request: Request, completion: @escaping (CGImage) -> Void) -> Token {
        let key = request.cacheKey
        let waiter = UUID()
        if let pending = inFlight[key] {
            pending.waiters[waiter] = completion
            return Token(key: key, waiter: waiter)
        }
        let pending = InFlight()
        pending.waiters[waiter] = completion
        inFlight[key] = pending
        let finish: @Sendable (CGImage?) -> Void = { image in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { MediaLoader.shared.finish(key: key, image: image) }
            }
        }
        switch request.kind {
        case .image:
            let url = request.url, maxPixel = request.maxPixel
            let op = BlockOperation()
            op.addExecutionBlock { [unowned op] in
                guard !op.isCancelled else { return }
                finish(Self.decode(url: url, maxPixel: maxPixel))
            }
            pending.operation = op
            queue.addOperation(op)
        case .videoThumbnail:
            let side = CGFloat(request.maxPixel)
            let thumb = QLThumbnailGenerator.Request(fileAt: request.url, size: CGSize(width: side, height: side),
                                                     scale: 1, representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: thumb) { rep, _ in
                finish(rep?.cgImage)
            }
        }
        return Token(key: key, waiter: waiter)
    }

    func cancel(_ token: Token) {
        guard let pending = inFlight[token.key] else { return }
        pending.waiters[token.waiter] = nil
        if pending.waiters.isEmpty, let op = pending.operation, !op.isExecuting {
            op.cancel()
            inFlight[token.key] = nil
        }
    }

    private func finish(key: String, image: CGImage?) {
        let pending = inFlight.removeValue(forKey: key)
        guard let image else { return }
        cache.setObject(image, forKey: key as NSString, cost: image.bytesPerRow * image.height)
        pending?.waiters.values.forEach { $0(image) }
    }

    nonisolated private static func decode(url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Longest bitmap side needed to cover `display` points (aspect-fill) at `scale`, never more
    /// than the source has.
    static func maxPixel(source: CGSize, display: CGSize, scale: CGFloat) -> Int {
        guard source.width > 0, source.height > 0 else { return Int(ceil(max(display.width, display.height) * scale)) }
        let factor = max(display.width / source.width, display.height / source.height) * scale
        return Int(ceil(min(1, factor) * max(source.width, source.height)))
    }
}

/// Opens a picture in the Quick Look panel (falls back to the default app).
@MainActor
final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLookCoordinator()
    private var url: URL?

    func preview(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else {
            NSWorkspace.shared.open(url)
            return
        }
        if panel.isVisible {
            panel.reloadData()
            return
        }
        panel.updateController()
        panel.makeKeyAndOrderFront(nil)
        if panel.currentController == nil {
            // Nothing in the responder chain took control of the panel: use the default app.
            panel.orderOut(nil)
            NSWorkspace.shared.open(url)
        }
    }

    /// Called from the responder chain (`AppDelegate`) when the panel looks for a controller.
    func begin(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.reloadData()
    }

    func end(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { url == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { url as NSURL? }
    }
}
