import Foundation

/// Watches chat.db, chat.db-wal and their folder with vnode sources, plus a slow safety-net poll
/// of a change token. Changes are debounced and delivered on the main queue.
final class DatabaseWatcher: @unchecked Sendable {
    private let dbPath: String
    private let directory: String
    private let debounce: TimeInterval
    private let pollInterval: TimeInterval
    private let changeToken: () -> String?
    private let queue = DispatchQueue(label: "LionMessages.watcher", qos: .utility)

    // Guarded by `lock`: read from the main queue at delivery time.
    private let lock = NSLock()
    private var handler: (() -> Void)?

    // Queue-confined state.
    private var fileSources: [String: (source: DispatchSourceFileSystemObject, inode: ino_t)] = [:]
    private var dirSource: DispatchSourceFileSystemObject?
    private var pollTimer: DispatchSourceTimer?
    private var pending: DispatchWorkItem?
    private var lastToken: String?
    private var running = false

    init(databasePath: String, debounce: TimeInterval = 0.25, pollInterval: TimeInterval = 3,
         changeToken: @escaping () -> String?) {
        dbPath = databasePath
        directory = (databasePath as NSString).deletingLastPathComponent
        self.debounce = debounce
        self.pollInterval = pollInterval
        self.changeToken = changeToken
    }

    deinit {
        // Sources hold `self` weakly; cancelling closes their fds.
        fileSources.values.forEach { $0.source.cancel() }
        dirSource?.cancel()
        pollTimer?.cancel()
    }

    func start(onChange: @escaping () -> Void) {
        lock.lock(); handler = onChange; lock.unlock()
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            self.lastToken = self.changeToken()
            self.armDirectory()
            self.rearmFiles()
            self.startPolling()
        }
    }

    func stop() {
        lock.lock(); handler = nil; lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.pending?.cancel(); self.pending = nil
            self.fileSources.values.forEach { $0.source.cancel() }
            self.fileSources.removeAll()
            self.dirSource?.cancel(); self.dirSource = nil
            self.pollTimer?.cancel(); self.pollTimer = nil
        }
    }

    // MARK: - Sources (on `queue`)

    private func makeSource(path: String, mask: DispatchSource.FileSystemEvent) -> (DispatchSourceFileSystemObject, ino_t)? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        var st = stat()
        let inode: ino_t = fstat(fd, &st) == 0 ? st.st_ino : 0
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: queue)
        source.setCancelHandler { close(fd) }
        return (source, inode)
    }

    private func armDirectory() {
        guard dirSource == nil, let (source, _) = makeSource(path: directory, mask: [.write, .delete, .rename]) else { return }
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.rearmFiles()
            self.scheduleFire()
        }
        dirSource = source
        source.resume()
    }

    /// (Re)creates sources for the db and -wal files when missing or replaced (new inode).
    private func rearmFiles() {
        guard running else { return }
        for path in [dbPath, dbPath + "-wal"] {
            var st = stat()
            let exists = stat(path, &st) == 0
            if let existing = fileSources[path], !exists || existing.inode != st.st_ino {
                existing.source.cancel()
                fileSources[path] = nil
            }
            guard exists, fileSources[path] == nil,
                  let (source, inode) = makeSource(path: path, mask: [.write, .extend, .delete, .rename, .attrib])
            else { continue }
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source else { return }
                if !source.data.intersection([.delete, .rename]).isEmpty {
                    source.cancel()
                    if self.fileSources[path]?.source === source { self.fileSources[path] = nil }
                    self.rearmFiles()
                }
                self.scheduleFire()
            }
            fileSources[path] = (source, inode)
            source.resume()
        }
    }

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            let token = self.changeToken()
            if let token, token != self.lastToken {
                self.lastToken = token
                self.scheduleFire()
            }
            self.rearmFiles() // picks up a -wal file that appeared without a directory event
        }
        pollTimer = timer
        timer.resume()
    }

    private func scheduleFire() {
        guard running else { return }
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.pending = nil
            if let token = self.changeToken() { self.lastToken = token }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock(); let handler = self.handler; self.lock.unlock()
                handler?()
            }
        }
        pending = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }
}
