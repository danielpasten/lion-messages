import AppKit
import MessagesData
import MessagesModel
import Quartz
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let options: LaunchOptions
    private var window: NSWindow!
    private var store: AppStore!
    private var decoyWindow: NSWindow?
    private var demoService: DemoMessagesService?
    private var sequenceStarted = false

    init(options: LaunchOptions) {
        self.options = options
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unbundled during development: become a regular, foreground app.
        NSApp.setActivationPolicy(.regular)
        switch options.appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        NSApp.mainMenu = makeMainMenu()
        // A still snapshot must show a fully settled frame; a frame sequence wants the motion.
        LionMotion.isDisabled = options.snapshotPath != nil && options.sequenceDir == nil
        LionMotion.forceReduceMotion = options.reduceMotion
        LionMotion.timeScale = options.slowMotion

        let service: MessagesService
        if options.demo {
            let demo = DemoMessagesService()
            demo.simulatedSendError = options.demoSendError
            if options.demoAccessAfter != nil { demo.hasAccess = false }
            demoService = demo
            service = demo
        } else {
            service = LiveMessagesService()
        }
        store = AppStore(service: service, forcePermissionScreen: options.forcePermissionScreen,
                         initialSelectionIndex: options.selectIndex, buddyPicturesOverride: options.buddyPictures)
        if let draft = options.draft { store.draft = draft }
        if let search = options.search { store.searchText = search }

        makeWindow()
        store.start()
        if let presentError = options.presentError {
            after(0.5) { [weak self] in
                self?.beginSequence("error")
                self?.store.presentedError = PresentedError(error: presentError)
            }
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if options.draft != nil {
            after(0.4) { [weak self] in
                guard let self else { return }
                self.store.focusComposer.send()
                if self.options.sendDraft {
                    // Let the focus ring settle first so a frame sequence shows only the send.
                    self.after(self.options.sequenceDir == nil ? 0 : 0.4) {
                        self.beginSequence("send")
                        self.store.sendDraft()
                    }
                }
            }
        }
        if options.inactive {
            // Hand key status to an invisible window so the main window draws inactive.
            after(0.6) {
                self.beginSequence("inactive")
                let decoy = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 10, height: 10),
                                     styleMask: [.titled], backing: .buffered, defer: false)
                decoy.isReleasedWhenClosed = false
                decoy.makeKeyAndOrderFront(nil)
                self.decoyWindow = decoy
            }
        }
        scheduleDebugTriggers()

        if let path = options.snapshotPath {
            after(snapshotDelay) { [weak self] in
                self?.snapshot(to: path)
            }
        }
    }

    private func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { work() } }
    }

    /// Long enough for every scheduled debug action to have happened and settled.
    private var snapshotDelay: Double {
        let last = [options.demoIncomingAfter, options.demoAccessAfter, options.toggleBuddyPicturesAfter,
                    options.resizeTo.map { _ in options.resizeAfter + Double(options.resizeSteps) / 60 }]
            .compactMap { $0 }.max() ?? 0
        return max(1.5, last + 0.8)
    }

    private func scheduleDebugTriggers() {
        if let delay = options.demoIncomingAfter, let demo = demoService {
            after(delay) { [weak self] in
                guard let self else { return }
                // The open conversation, plus one further down so the sidebar reorders.
                let list = self.store.conversations
                var ids: [Int64] = []
                if let selected = self.store.selectedConversationID { ids.append(selected) }
                if let other = list.dropFirst(3).first(where: { !ids.contains($0.id) }) { ids.append(other.id) }
                self.beginSequence("incoming")
                demo.deliverIncoming(to: ids, withPicture: self.options.demoIncomingPicture)
            }
        }
        if let delay = options.demoAccessAfter, let demo = demoService {
            after(delay) { [weak self] in
                self?.beginSequence("access")
                demo.hasAccess = true
                self?.store.checkAgain()
            }
        }
        if let delay = options.toggleBuddyPicturesAfter {
            after(delay) { [weak self] in
                guard let self else { return }
                self.beginSequence("buddy")
                self.store.setShowBuddyPictures(!self.store.showBuddyPictures, persist: false)
            }
        }
        if let target = options.focus {
            after(0.8) { [weak self] in
                guard let self else { return }
                self.beginSequence("focus")
                if target == "search" { self.focusSearch(nil) } else { self.store.focusComposer.send() }
            }
        }
        if let points = options.scrollTranscript {
            after(1.0) { [weak self] in
                guard let self, let scroll = self.findTranscriptScrollView(in: self.window.contentView) else { return }
                self.beginSequence("scroll")
                let clip = scroll.contentView
                clip.scroll(to: NSPoint(x: 0, y: max(0, clip.bounds.minY - points)))
                scroll.reflectScrolledClipView(clip)
            }
        }
        if let target = options.resizeTo {
            after(options.resizeAfter) { [weak self] in
                guard let self else { return }
                self.beginSequence("resize")
                let start = self.window.frame
                let content = self.window.contentRect(forFrameRect: start)
                let end = self.window.frameRect(forContentRect: NSRect(
                    x: content.minX, y: content.maxY - target.height, width: target.width, height: target.height))
                let steps = self.options.resizeSteps
                // Like dragging the bottom-right corner: the top-left stays put.
                for i in 1...steps {
                    self.after(Double(i - 1) / 60) {
                        let t = CGFloat(i) / CGFloat(steps)
                        let w = start.width + (end.width - start.width) * t
                        let h = start.height + (end.height - start.height) * t
                        self.window.setFrame(NSRect(x: start.minX, y: start.maxY - h, width: w, height: h), display: true)
                    }
                }
            }
        }
    }

    private func findTranscriptScrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scroll = view as? NSScrollView, scroll.documentView is TranscriptTableView { return scroll }
        for sub in view.subviews { if let s = findTranscriptScrollView(in: sub) { return s } }
        return nil
    }

    private func makeWindow() {
        let size = options.size ?? NSSize(width: 980, height: 640)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Lion Messages"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 460)
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.delegate = self

        let hosting = NSHostingView(rootView: RootView(store: store))
        hosting.sizingOptions = []
        window.contentView = hosting
        window.setContentSize(size)
        window.center()
        window.setFrameAutosaveName(options.snapshotPath == nil && options.size == nil ? "LionMessagesMain" : "")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc private func refresh(_ sender: Any?) { store.refresh() }

    @objc private func focusSearch(_ sender: Any?) {
        guard let field = findSearchField(in: window.contentView) else { return }
        window.makeFirstResponder(field.textField)
    }

    private func findSearchField(in view: NSView?) -> LionSearchField? {
        guard let view else { return nil }
        if let field = view as? LionSearchField { return field }
        for sub in view.subviews { if let f = findSearchField(in: sub) { return f } }
        return nil
    }

    @objc private func showMainWindow(_ sender: Any?) { window.makeKeyAndOrderFront(nil) }

    @objc private func toggleBuddyPictures(_ sender: Any?) {
        store.setShowBuddyPictures(!store.showBuddyPictures)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleBuddyPictures(_:)) {
            menuItem.state = store?.showBuddyPictures == true ? .on : .off
        }
        return true
    }

    // MARK: Quick Look (the panel finds its controller through the responder chain)

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { QuickLookCoordinator.shared.begin(panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { QuickLookCoordinator.shared.end(panel) }

    // MARK: Snapshot (verification without Screen Recording permission)

    private func snapshot(to path: String) {
        waitForMedia(until: CACurrentMediaTime() + 8) { [self] in
            // Show the overlay scrollers so they appear in the picture.
            flashScrollers(in: window.contentView)
            after(0.2) { [self] in
                guard let rep = captureWindow(), let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
                do {
                    try data.write(to: URL(fileURLWithPath: path))
                    exit(0)
                } catch {
                    FileHandle.standardError.write("snapshot failed: \(error.localizedDescription)\n".data(using: .utf8)!)
                    exit(1)
                }
            }
        }
    }

    /// A settled frame: visible pictures, thumbnails and buddy pictures have finished loading
    /// (checked twice in a row, since a finished load can start the next visible one).
    private func waitForMedia(until deadline: CFTimeInterval, quietChecks: Int = 0, _ done: @escaping @MainActor () -> Void) {
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let idle = MediaLoader.shared.isIdle && !store.isLoadingBuddyPictures
        if (idle && quietChecks >= 2) || CACurrentMediaTime() > deadline {
            done()
            return
        }
        after(0.05) { [weak self] in
            self?.waitForMedia(until: deadline, quietChecks: idle ? quietChecks + 1 : 0, done)
        }
    }

    private func captureWindow() -> NSBitmapImageRep? {
        guard let frameView = window.contentView?.superview else { return nil }
        LionTween.tickNow()
        frameView.layoutSubtreeIfNeeded()
        frameView.displayIfNeeded()
        let bounds = frameView.bounds
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = bounds.size
        frameView.cacheDisplay(in: bounds, to: rep)
        return rep
    }

    /// `--snapshot-sequence`: frame 0 is captured right as the trigger fires (before its effect),
    /// then one frame every `--interval` ms on wall-clock time; the app exits when done.
    private func beginSequence(_ trigger: String) {
        guard let dir = options.sequenceDir, !sequenceStarted,
              options.sequenceOn == nil || options.sequenceOn == trigger else { return }
        sequenceStarted = true
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let start = CACurrentMediaTime()
        let count = max(1, options.frames)
        let interval = options.intervalMs / 1000
        var frames: [(NSBitmapImageRep, Double)] = []
        func capture(_ i: Int) {
            if let rep = captureWindow() { frames.append((rep, (CACurrentMediaTime() - start) * 1000)) }
            if i + 1 < count {
                let next = start + Double(i + 1) * interval
                after(max(0, next - CACurrentMediaTime())) { capture(i + 1) }
            } else {
                var log = ""
                for (n, (rep, ms)) in frames.enumerated() {
                    let name = String(format: "frame-%02d.png", n)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/" + name))
                    log += String(format: "%@ %.0f ms\n", name, ms)
                }
                try? log.write(toFile: dir + "/frames.txt", atomically: true, encoding: .utf8)
                exit(0)
            }
        }
        capture(0)
    }

    private func flashScrollers(in view: NSView?) {
        guard let view else { return }
        if let scroll = view as? NSScrollView { scroll.flashScrollers() }
        view.subviews.forEach(flashScrollers)
    }

    // MARK: Menus

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appName = "Lion Messages"

        let app = NSMenu(title: appName)
        app.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let services = NSMenu(title: "Services")
        app.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: appName, action: nil, keyEquivalent: "").submenu = app

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "V")
            .keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let find = edit.addItem(withTitle: "Find…", action: #selector(focusSearch(_:)), keyEquivalent: "f")
        find.target = self
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit

        let view = NSMenu(title: "View")
        let refresh = view.addItem(withTitle: "Refresh", action: #selector(refresh(_:)), keyEquivalent: "r")
        refresh.target = self
        view.addItem(.separator())
        let buddies = view.addItem(withTitle: "Show Buddy Pictures", action: #selector(toggleBuddyPictures(_:)),
                                   keyEquivalent: "b")
        buddies.keyEquivalentModifierMask = [.command, .shift]
        buddies.target = self
        view.addItem(.separator())
        view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
        main.addItem(withTitle: "View", action: nil, keyEquivalent: "").submenu = view

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(.separator())
        let show = windowMenu.addItem(withTitle: "Lion Messages", action: #selector(showMainWindow(_:)), keyEquivalent: "0")
        show.target = self
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        return main
    }
}
