import Foundation
import MessagesModel

/// Copies files into a folder Messages.app can read before they are handed to it by AppleScript.
///
/// Messages is sandboxed: when a script gives it a file from an arbitrary place (a temporary
/// folder, the Desktop, another app's container) the send often fails or silently never arrives.
/// A subfolder of `~/Pictures` is the widely used workaround. Each file gets its own
/// `<uuid>/` folder so the original name is kept and names never collide. Copies are not deleted
/// right after sending (Messages reads them asynchronously); `cleanUp` removes old ones later.
final class AttachmentOutbox: @unchecked Sendable {
    /// Files larger than this are refused before anything runs.
    static let maxFileSize: Int64 = 100 * 1024 * 1024
    /// Staged copies older than this are removed by `cleanUp`.
    static let retention: TimeInterval = 24 * 60 * 60

    /// `~/Pictures/Lion Messages Outbox`.
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures", isDirectory: true)
            .appendingPathComponent("Lion Messages Outbox", isDirectory: true)
    }

    let directory: URL
    private let fileManager = FileManager.default

    init(directory: URL = AttachmentOutbox.defaultDirectory) {
        self.directory = directory
    }

    /// Checks that every file can be sent: it exists, is a regular readable file and is not too
    /// large. The error message names the file only (never its path).
    static func validate(_ urls: [URL]) throws {
        for url in urls {
            let name = url.lastPathComponent
            guard url.isFileURL else { throw SendError.scriptFailed("“\(name)” isn’t a file on this Mac.") }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
            guard let values, FileManager.default.fileExists(atPath: url.path) else {
                throw SendError.scriptFailed("“\(name)” couldn’t be found.")
            }
            if values.isDirectory == true {
                throw SendError.scriptFailed("“\(name)” is a folder. Only files can be sent.")
            }
            guard values.isRegularFile == true, FileManager.default.isReadableFile(atPath: url.path) else {
                throw SendError.scriptFailed("“\(name)” can’t be read.")
            }
            if Int64(values.fileSize ?? 0) > maxFileSize {
                throw SendError.scriptFailed("“\(name)” is larger than 100 MB and can’t be sent.")
            }
        }
    }

    /// Copies `url` to `<directory>/<uuid>/<original name>` and returns the copy.
    func stage(_ url: URL) throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(url.lastPathComponent)
            try fileManager.copyItem(at: url, to: target)
            return target
        } catch {
            try? fileManager.removeItem(at: folder)
            throw SendError.scriptFailed("“\(url.lastPathComponent)” couldn’t be prepared for sending.")
        }
    }

    /// Removes staged folders last modified more than `retention` ago. Returns how many were removed.
    @discardableResult
    func cleanUp(now: Date = Date(), retention: TimeInterval = AttachmentOutbox.retention) -> Int {
        guard let items = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        else { return 0 }
        var removed = 0
        for item in items {
            let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let date, now.timeIntervalSince(date) > retention else { continue }
            if (try? fileManager.removeItem(at: item)) != nil { removed += 1 }
        }
        return removed
    }
}
