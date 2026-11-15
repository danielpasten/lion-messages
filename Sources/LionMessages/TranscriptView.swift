import AppKit
import Combine
import MessagesModel
import SwiftUI

// iChat-on-Lion transcript: an NSTableView of glossy bubbles, timestamps and sender names.

private enum TranscriptRow {
    case padding(CGFloat)
    /// Timestamp and sender rows belong to the message that follows them (`owner`), so they
    /// fade in together with it.
    case timestamp(day: String, time: String, owner: Int64)
    case sender(String, owner: Int64, inset: CGFloat)
    case message(Message, gapAbove: CGFloat, avatar: AvatarSlot)

    var owner: Int64? {
        switch self {
        case .padding: return nil
        case .timestamp(_, _, let owner), .sender(_, let owner, _): return owner
        case .message(let m, _, _): return m.id
        }
    }
}

@MainActor
final class TranscriptController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let scrollView = LionScrollView()
    private let tableView = TranscriptTableView()
    private weak var store: AppStore?
    private let layout = TranscriptLayout()
    private var rows: [TranscriptRow] = []
    private var messageRow: [Int64: Int] = [:]
    private var state = TranscriptState.empty
    private var pinnedToBottom = true
    private var lastWidth: CGFloat = 0
    private var cancellables: Set<AnyCancellable> = []

    // Motion
    private var scrollTween: LionTween?
    private var arrivals: [Int64: BubbleArrival] = [:]
    private var crossfade: TranscriptCrossfadeView?
    private var crossfadeTween: LionTween?
    private var crossfadeHold: DispatchWorkItem?

    init(store: AppStore) {
        self.store = store
        super.init()
        let column = NSTableColumn(identifier: .init("transcript"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .fullWidth
        tableView.intercellSpacing = .zero
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.focusRingType = .none
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.onAppearanceChange = { [weak self] in self?.applyAppearance() }
        scrollView.documentView = tableView
        scrollView.drawsBackground = true
        applyAppearance()

        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification, object: clip)
            .sink { [weak self] _ in self?.clipBoundsChanged() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSView.frameDidChangeNotification, object: clip)
            .sink { [weak self] _ in self?.clipFrameChanged() }
            .store(in: &cancellables)

        store.$transcript
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.apply(state) }
            .store(in: &cancellables)
        store.$showBuddyPictures
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.buddyPicturesChanged() }
            .store(in: &cancellables)
        store.buddyPicturesDidLoad
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refreshVisibleBuddyPictures() }
            .store(in: &cancellables)
    }

    private var showsBuddyPictures: Bool { store?.showBuddyPictures ?? false }

    private var palette: LionPalette { LionTheme.palette(for: tableView.effectiveAppearance) }

    private func applyAppearance() {
        finishArrivals()
        let bg = palette.transcriptBackground
        tableView.backgroundColor = bg
        scrollView.backgroundColor = bg
        tableView.reloadData()
    }

    // MARK: Scrolling

    private var columnWidth: CGFloat { scrollView.contentView.bounds.width }

    private var isAtBottom: Bool {
        let clip = scrollView.contentView
        return clip.bounds.maxY >= tableView.frame.height - 24
    }

    private var isAnimatingScroll: Bool { scrollTween.map { !$0.isFinished } ?? false }

    private func clipBoundsChanged() {
        // An animated scroll to the bottom keeps the transcript pinned while it travels.
        if !isAnimatingScroll { pinnedToBottom = isAtBottom }
    }

    private func clipFrameChanged() {
        let width = columnWidth
        let wasPinned = pinnedToBottom
        if abs(width - lastWidth) > 0.5 {
            // The column changed width (live resize, full screen, zoom): every bubble re-wraps to
            // the new maximum width and every row height is recomputed. No arrival animations.
            lastWidth = width
            finishArrivals()
            let anchor = wasPinned ? nil : visibleAnchor()
            layout.trimCache(keeping: Set(state.messages.map(\.id)))
            // A full reload re-queries every row height (measurements are cached per width) and
            // reconfigures the visible cells; noteHeightOfRows left stale heights behind.
            tableView.reloadData()
            if let anchor { restore(anchor) }
        }
        // A running scroll animation retargets the (new) bottom by itself.
        if wasPinned && !isAnimatingScroll {
            scrollToBottom()
            // The table may settle its height after this notification; re-pin once it has.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pinnedToBottom, !self.isAnimatingScroll else { return }
                if abs(self.scrollView.contentView.bounds.minY - self.bottomY) > 0.25 { self.scrollToBottom() }
            }
        }
    }

    func scrollToBottom() {
        scrollTween?.cancel()
        tableView.tile()
        tableView.layoutSubtreeIfNeeded()
        setScroll(y: .greatestFiniteMagnitude)
        pinnedToBottom = true
    }

    private var bottomY: CGFloat { max(0, tableView.frame.height - scrollView.contentView.bounds.height) }

    private func setScroll(y: CGFloat) {
        let clip = scrollView.contentView
        // Whole device pixels, so the same content always lands on the same pixels.
        let scale = scrollView.window?.backingScaleFactor ?? 2
        let y = (max(0, min(y, bottomY)) * scale).rounded() / scale
        clip.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Smooth scroll to the bottom (new message while at the bottom, or one the user sent).
    private func animateScrollToBottom() {
        tableView.layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        let from = clip.bounds.minY
        scrollTween?.cancel()
        guard !LionMotion.reduceMotion, bottomY - from > 0.5 else { return scrollToBottom() }
        pinnedToBottom = true
        var lastY = from
        scrollTween = LionTween.run(duration: LionMotion.transcriptScroll, curve: .easeOut, update: { [weak self] t in
            guard let self else { return }
            if abs(clip.bounds.minY - lastY) > 1 {
                // The user scrolled during the animation: they win.
                self.scrollTween?.cancel()
                self.pinnedToBottom = self.isAtBottom
                return
            }
            self.setScroll(y: from + (self.bottomY - from) * t)
            lastY = clip.bounds.minY
        }, completion: { [weak self] in
            self?.pinnedToBottom = true
        })
    }

    /// The first visible bubble and its distance from the top of the visible area.
    private func visibleAnchor() -> (id: Int64, offset: CGFloat)? {
        let visible = scrollView.contentView.bounds
        let range = tableView.rows(in: visible)
        guard range.length > 0 else { return nil }
        for row in range.location..<min(range.location + range.length, rows.count) {
            if case .message(let m, _, _) = rows[row] {
                return (m.id, tableView.rect(ofRow: row).minY - visible.minY)
            }
        }
        return nil
    }

    private func restore(_ anchor: (id: Int64, offset: CGFloat)) {
        guard let row = messageRow[anchor.id] else { return }
        tableView.layoutSubtreeIfNeeded()
        setScroll(y: tableView.rect(ofRow: row).minY - anchor.offset)
    }

    // MARK: Updates

    private func apply(_ new: TranscriptState) {
        let old = state
        let sameConversation = old.conversationID == new.conversationID
        if sameConversation, old.messages == new.messages, old.isGroup == new.isGroup {
            // The store reloads wholesale; nothing changed for this conversation.
            state = new
            if new.reason == .sent { animateScrollToBottom() }
            return
        }

        if !sameConversation || old.messages.isEmpty {
            // Opening a conversation: no per-bubble motion, land at the bottom, quick crossfade.
            finishArrivals()
            if !sameConversation {
                beginCrossfade(holdForLoad: new.messages.isEmpty && new.conversationID != nil)
            }
            state = new
            rebuildRows()
            tableView.reloadData()
            layout.trimCache(keeping: Set(new.messages.map(\.id)))
            scrollToBottom()
            if !new.messages.isEmpty || new.conversationID == nil { releaseCrossfade() }
            return
        }

        // Same conversation, real diff: keep everything where it is on screen, then animate.
        let wasAtBottom = isAtBottom || pinnedToBottom
        let anchor = visibleAnchor()
        let oldIDs = Set(old.messages.map(\.id))
        let appended = Array(new.messages.reversed().prefix { !oldIDs.contains($0.id) }.reversed())
        let lastChanged = new.messages.last?.id != old.messages.last?.id
        state = new
        rebuildRows()
        tableView.reloadData()
        layout.trimCache(keeping: Set(new.messages.map(\.id)))
        if let anchor { restore(anchor) }

        if new.reason == .sent || wasAtBottom || (lastChanged && new.messages.last?.isFromMe == true) {
            animateScrollToBottom()
        }
        // A handful of new messages animate in; a big batch (e.g. a sync) just appears.
        if appended.count <= 3 {
            for m in appended { startArrival(of: m) }
        }
    }

    private func rebuildRows() {
        var out: [TranscriptRow] = [.padding(8)]
        var index: [Int64: Int] = [:]
        let buddies = showsBuddyPictures
        let messages = state.messages
        // A run is consecutive messages from one sender with no timestamp between them; its
        // buddy picture sits beside the last one and its column stays reserved for the others.
        var needsTimestamp: [Bool] = []
        var continuesRun: [Bool] = []
        for (i, m) in messages.enumerated() {
            let previous = i > 0 ? messages[i - 1] : nil
            let stamp: Bool = {
                guard let previous else { return true }
                return m.date.timeIntervalSince(previous.date) > 15 * 60
                    || !Calendar.current.isDate(m.date, inSameDayAs: previous.date)
            }()
            needsTimestamp.append(stamp)
            continuesRun.append(!stamp && previous.map { $0.isFromMe == m.isFromMe && $0.senderHandle == m.senderHandle } == true)
        }
        let senderInset = BubbleMetrics.sideMargin + BubbleMetrics.padX + (buddies ? BuddyMetrics.column : 0)
        for (i, m) in messages.enumerated() {
            var gap: CGFloat = 10
            var showSender = state.isGroup && !m.isFromMe
            if needsTimestamp[i] {
                let full = LionDateFormat.transcript(m.date)
                let time = LionDateFormat.transcriptTime(m.date)
                let day = full.hasSuffix(time) ? String(full.dropLast(time.count)) : full
                out.append(.timestamp(day: day, time: full.hasSuffix(time) ? time : "", owner: m.id))
                gap = 2
            } else if continuesRun[i] {
                gap = 3
                showSender = false
            }
            if showSender {
                out.append(.sender(m.senderName ?? m.senderHandle ?? "Unknown", owner: m.id, inset: senderInset))
                gap = 1
            }
            let slot: AvatarSlot = !buddies ? .none : (i + 1 < messages.count && continuesRun[i + 1]) ? .reserved : .shown
            index[m.id] = out.count
            out.append(.message(m, gapAbove: gap, avatar: slot))
        }
        out.append(.padding(12))
        rows = out
        messageRow = index
    }

    private func geometry(_ m: Message, gap: CGFloat, slot: AvatarSlot) -> MessageGeometry {
        layout.geometry(for: m, columnWidth: columnWidth, gap: gap, slot: slot)
    }

    private func buddyPicture(for m: Message, slot: AvatarSlot) -> NSImage? {
        guard slot == .shown else { return nil }
        return store?.buddyPicture(isFromMe: m.isFromMe, handle: m.senderHandle)
    }

    // MARK: Buddy pictures

    /// View ▸ Show Buddy Pictures: every row is re-measured, like a width change (no motion).
    private func buddyPicturesChanged() {
        let wasPinned = pinnedToBottom
        finishArrivals()
        let anchor = wasPinned ? nil : visibleAnchor()
        rebuildRows()
        tableView.reloadData()
        if let anchor { restore(anchor) } else if wasPinned && !isAnimatingScroll { scrollToBottom() }
    }

    /// A picture finished loading: pictures never change a row's size, so just hand it over.
    private func refreshVisibleBuddyPictures() {
        tableView.enumerateAvailableRowViews { rowView, row in
            guard row < rows.count, case .message(let m, _, let slot) = rows[row], slot == .shown,
                  let cell = rowView.view(atColumn: 0) as? MessageCell else { return }
            cell.setAvatar(buddyPicture(for: m, slot: slot))
        }
    }

    // MARK: Arrival animation (iChat: rise, fade and grow from the bubble's tail side)

    private func startArrival(of m: Message) {
        guard arrivals[m.id] == nil, let row = messageRow[m.id], case .message(_, let gap, let slot) = rows[row] else { return }
        let cellRect = tableView.frameOfCell(atColumn: 0, row: row)
        let g = geometry(m, gap: gap, slot: slot)
        let frame = g.contentFrame(cellWidth: cellRect.width)
        let scale = tableView.window?.backingScaleFactor ?? 2
        let stage = MessageCell.stage(message: m, geometry: g, avatar: buddyPicture(for: m, slot: slot),
                                      cellSize: cellRect.size, appearance: tableView.effectiveAppearance)
        guard let image = stage.lionSnapshot(of: frame, scale: scale) else { return }
        let overlay = BubbleArrivalView(image: image, isFromMe: m.isFromMe, reduceMotion: LionMotion.reduceMotion)
        let arrival = BubbleArrival(overlay: overlay, stage: stage, rect: frame, scale: scale)
        let id = m.id
        // A picture that decodes mid-animation shows up in the stand-in right away.
        stage.onImageLoaded = { [weak self, weak arrival] in
            guard let self, let arrival, self.arrivals[id] === arrival,
                  let image = arrival.stage.lionSnapshot(of: arrival.rect, scale: arrival.scale) else { return }
            arrival.overlay.image = image
        }
        arrivals[m.id] = arrival
        tableView.addSubview(overlay)
        setArrivalCellsHidden(m.id, progress: 0)
        arrival.tween = LionTween.run(duration: LionMotion.bubbleArrival, curve: .easeOut, update: { [weak self] t in
            self?.updateArrival(m.id, progress: t)
        }, completion: { [weak self] in
            self?.endArrival(m.id)
        })
    }

    private func updateArrival(_ id: Int64, progress: CGFloat) {
        guard let arrival = arrivals[id], let row = messageRow[id], case .message(let m, let gap, let slot) = rows[row]
        else { return }
        // The cell's frame, not the row's: the table insets cells within their rows.
        let cellRect = tableView.frameOfCell(atColumn: 0, row: row)
        var frame = geometry(m, gap: gap, slot: slot).contentFrame(cellWidth: cellRect.width)
        frame.origin.x += cellRect.minX
        frame.origin.y += cellRect.minY
        arrival.overlay.place(bubbleFrame: frame, progress: progress)
        // Row views added later (scrolling into view) would cover the overlay.
        if tableView.subviews.last !== arrival.overlay {
            tableView.addSubview(arrival.overlay, positioned: .above, relativeTo: nil)
        }
        setArrivalCellsHidden(id, progress: progress)
    }

    /// Hides the real bubble while its stand-in animates, and fades its timestamp/sender rows.
    private func setArrivalCellsHidden(_ id: Int64, progress: CGFloat) {
        guard let row = messageRow[id] else { return }
        for r in max(0, row - 2)...row where rows[r].owner == id {
            guard let view = tableView.view(atColumn: 0, row: r, makeIfNecessary: false) else { continue }
            applyArrivalState(to: view, id: id, progress: progress)
        }
    }

    private func applyArrivalState(to view: NSView, id: Int64, progress: CGFloat?) {
        switch view {
        case let cell as MessageCell: cell.isArriving = progress != nil
        case let cell as TimestampCell: cell.opacity = progress ?? 1
        case let cell as SenderCell: cell.opacity = progress ?? 1
        default: break
        }
    }

    private func endArrival(_ id: Int64) {
        guard let arrival = arrivals.removeValue(forKey: id) else { return }
        arrival.overlay.removeFromSuperview()
        if let row = messageRow[id] {
            for r in max(0, row - 2)...row where rows[r].owner == id {
                if let view = tableView.view(atColumn: 0, row: r, makeIfNecessary: false) {
                    applyArrivalState(to: view, id: id, progress: nil)
                }
            }
        }
    }

    private func finishArrivals() {
        for (id, arrival) in arrivals {
            arrival.tween?.cancel()
            endArrival(id)
        }
    }

    // MARK: Conversation switch crossfade

    /// Covers the transcript with a picture of what it shows now. With `holdForLoad`, the picture
    /// stays until the new conversation's messages arrive (or a short timeout), then fades.
    private func beginCrossfade(holdForLoad: Bool) {
        crossfadeHold?.cancel()
        crossfadeTween?.cancel()
        crossfadeTween = nil
        let bounds = scrollView.bounds
        guard !LionMotion.isDisabled, scrollView.window != nil, !state.messages.isEmpty || crossfade != nil,
              bounds.width > 0, bounds.height > 0,
              let image = scrollView.lionSnapshot() else {
            crossfade?.removeFromSuperview()
            crossfade = nil
            return
        }
        crossfade?.removeFromSuperview()
        let view = TranscriptCrossfadeView(frame: bounds)
        view.image = image
        view.autoresizingMask = [.width, .height]
        scrollView.addSubview(view, positioned: .above, relativeTo: scrollView.contentView)
        crossfade = view
        if holdForLoad {
            let hold = DispatchWorkItem { [weak self] in self?.releaseCrossfade() }
            crossfadeHold = hold
            DispatchQueue.main.asyncAfter(deadline: .now() + LionMotion.duration(LionMotion.transcriptLoadHold), execute: hold)
        }
    }

    private func releaseCrossfade() {
        crossfadeHold?.cancel()
        crossfadeHold = nil
        guard let view = crossfade, crossfadeTween == nil else { return }
        crossfadeTween = LionTween.run(duration: LionMotion.transcriptCrossfade, curve: .linear, update: { t in
            view.opacity = 1 - t
        }, completion: { [weak self] in
            view.removeFromSuperview()
            if self?.crossfade === view { self?.crossfade = nil }
            self?.crossfadeTween = nil
        })
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .padding(let h): return h
        case .timestamp: return 28
        case .sender: return 16
        case .message(let m, let gap, let slot):
            return geometry(m, gap: gap, slot: slot).rowHeight
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view: NSView
        switch rows[row] {
        case .padding:
            return nil
        case .timestamp(let day, let time, _):
            let cell = reuse(TimestampCell.self, "Timestamp")
            cell.day = day
            cell.time = time
            view = cell
        case .sender(let name, _, let inset):
            let cell = reuse(SenderCell.self, "Sender")
            cell.name = name
            cell.inset = inset
            view = cell
        case .message(let m, let gap, let slot):
            // Plain text rows and rich rows reuse separately (their subviews differ).
            let cell = reuse(MessageCell.self, layout.isPlain(m) ? "Bubble" : "Rich")
            cell.configure(message: m, geometry: geometry(m, gap: gap, slot: slot), avatar: buddyPicture(for: m, slot: slot))
            view = cell
        }
        let id = rows[row].owner ?? 0
        applyArrivalState(to: view, id: id, progress: arrivals[id].map { _ in 0 })
        return view
    }

    private func reuse<T: NSView>(_ type: T.Type, _ id: String) -> T {
        let identifier = NSUserInterfaceItemIdentifier(id)
        if let view = tableView.makeView(withIdentifier: identifier, owner: nil) as? T { return view }
        let view = T(frame: .zero)
        view.identifier = identifier
        return view
    }
}

@MainActor
private final class BubbleArrival {
    let overlay: BubbleArrivalView
    /// The offscreen row the overlay pictures, kept while pictures may still finish loading.
    let stage: MessageCell
    let rect: NSRect
    let scale: CGFloat
    var tween: LionTween?
    init(overlay: BubbleArrivalView, stage: MessageCell, rect: NSRect, scale: CGFloat) {
        self.overlay = overlay
        self.stage = stage
        self.rect = rect
        self.scale = scale
    }
}

/// Stand-in for a new bubble while it arrives: draws the bubble's picture rising ~12 pt, fading
/// in and growing from 92% at its tail-side bottom corner. Reduce Motion: a plain fade.
private final class BubbleArrivalView: NSView {
    var image: NSImage { didSet { needsDisplay = true } }
    private let isFromMe: Bool
    private let reduceMotion: Bool
    private var progress: CGFloat = 0
    private static let margin: CGFloat = 4

    init(image: NSImage, isFromMe: Bool, reduceMotion: Bool) {
        self.image = image
        self.isFromMe = isFromMe
        self.reduceMotion = reduceMotion
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func place(bubbleFrame f: NSRect, progress: CGFloat) {
        let m = Self.margin
        frame = NSRect(x: f.minX - m, y: f.minY - m, width: f.width + 2 * m,
                       height: f.height + 2 * m + LionMotion.bubbleRise)
        self.progress = progress
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let m = Self.margin
        let body = NSRect(x: m, y: m, width: image.size.width, height: image.size.height)
        let p = progress
        let alpha = reduceMotion ? p : min(1, p * 1.4)
        if !reduceMotion {
            let scale = LionMotion.bubbleStartScale + (1 - LionMotion.bubbleStartScale) * p
            let anchor = NSPoint(x: isFromMe ? body.maxX : body.minX, y: body.maxY - BubbleMetrics.shadowRoom)
            ctx.translateBy(x: anchor.x, y: anchor.y + (1 - p) * LionMotion.bubbleRise)
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -anchor.x, y: -anchor.y)
        }
        image.draw(in: body, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
    }
}

/// The previous conversation's picture, fading out over the new one.
private final class TranscriptCrossfadeView: NSView {
    var image: NSImage?
    var opacity: CGFloat = 1 { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        image?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: opacity, respectFlipped: true, hints: nil)
    }
}

extension NSView {
    /// A Retina picture of the view as it is drawn right now (subviews included).
    func lionSnapshot(scale: CGFloat? = nil) -> NSImage? {
        let b = bounds
        let s = scale ?? window?.backingScaleFactor ?? 2
        guard b.width > 0, b.height > 0, let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(ceil(b.width * s)), pixelsHigh: Int(ceil(b.height * s)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = b.size
        cacheDisplay(in: b, to: rep)
        let image = NSImage(size: b.size)
        image.addRepresentation(rep)
        return image
    }
}

final class TranscriptTableView: NSTableView {
    var onAppearanceChange: () -> Void = {}

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange()
    }

    override var acceptsFirstResponder: Bool { false }
}

// MARK: - Cells

private final class TimestampCell: NSView {
    var day = "" { didSet { needsDisplay = true } }
    var time = "" { didSet { needsDisplay = true } }
    var opacity: CGFloat = 1 { didSet { if opacity != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.setAlpha(opacity)
        let p = LionTheme.palette(for: effectiveAppearance)
        let str = NSMutableAttributedString(string: day, attributes: [
            .font: LionFont.bold(10.5), .foregroundColor: p.timestamp,
        ])
        str.append(NSAttributedString(string: time, attributes: [
            .font: LionFont.regular(10.5), .foregroundColor: p.timestamp,
        ]))
        let size = str.size()
        str.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2 + 1))
    }
}

private final class SenderCell: NSView {
    var name = "" { didSet { needsDisplay = true } }
    var inset = BubbleMetrics.sideMargin + BubbleMetrics.padX { didSet { if inset != oldValue { needsDisplay = true } } }
    var opacity: CGFloat = 1 { didSet { if opacity != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.setAlpha(opacity)
        let p = LionTheme.palette(for: effectiveAppearance)
        let str = NSAttributedString(string: name, attributes: [
            .font: LionFont.regular(10), .foregroundColor: p.timestamp,
        ])
        str.draw(with: NSRect(x: inset, y: bounds.height - 14,
                              width: bounds.width * 0.65, height: 14),
                 options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

struct TranscriptRepresentable: NSViewRepresentable {
    let store: AppStore

    func makeCoordinator() -> TranscriptController { TranscriptController(store: store) }

    func makeNSView(context: Context) -> LionScrollView { context.coordinator.scrollView }

    func updateNSView(_ nsView: LionScrollView, context: Context) {}
}
