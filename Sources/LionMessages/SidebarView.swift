import AppKit
import Combine
import MessagesModel
import SwiftUI

/// One row of the sidebar table.
enum SidebarItem: Equatable {
    /// The grid of pinned conversations (only on the main list, when not searching).
    case pins
    /// The source-list header naming the sender list.
    case header
    case conversation(Conversation)

    var conversation: Conversation? {
        if case .conversation(let c) = self { return c }
        return nil
    }
}

/// Mail-on-Lion style conversation list: an NSTableView with hand-drawn rows, topped by
/// Messages-style pinned conversations.
@MainActor
final class SidebarController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    static let width: CGFloat = 260
    static let headerHeight: CGFloat = 28
    static let rowHeight: CGFloat = 52

    let scrollView = LionScrollView()
    let tableView = SidebarTableView()
    private weak var store: AppStore?
    private var items: [SidebarItem] = []
    private var pinned: [Conversation] = []
    private var headerTitle = ""
    private var selectedID: Int64?
    private var isSyncingSelection = false
    private var cancellables: Set<AnyCancellable> = []
    private let activeFader = LionActiveFader()
    private var lastSearchText = ""
    private var lastScope: SidebarScope?
    private var rowsAnimation: (overlay: SidebarRowsOverlay, tween: LionTween)?
    private weak var pinsView: SidebarPinsView?

    init(store: AppStore) {
        self.store = store
        super.init()

        let column = NSTableColumn(identifier: .init("conversation"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .fullWidth
        tableView.intercellSpacing = .zero
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.focusRingType = .none
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.onAppearanceChange = { [weak self] in self?.applyAppearance() }
        tableView.onWindowChange = { [weak self] window in self?.activeFader.attach(to: window) }
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu
        activeFader.onChange = { [weak self] in self?.applyActiveFraction() }
        scrollView.documentView = tableView
        scrollView.drawsBackground = true
        applyAppearance()

        // The store sets the pins and the scope before the rows, so the rows' change carries all three.
        store.$filteredConversations
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak store] list in
                guard let self, let store else { return }
                self.update(rows: list, pinned: store.pinnedConversations,
                            header: store.scope.header(filteringUnknown: store.filtersUnknownSenders))
            }
            .store(in: &cancellables)
        store.$selectedConversationID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in self?.update(selectedID: id) }
            .store(in: &cancellables)
        store.$showBuddyPictures
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.buddyPicturesChanged() }
            .store(in: &cancellables)
        store.buddyPicturesDidLoad
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refreshVisiblePictures() }
            .store(in: &cancellables)
    }

    // MARK: Buddy pictures

    private func configurePicture(_ cell: SidebarCell, _ c: Conversation) {
        let show = store?.showBuddyPictures ?? false
        cell.showsPicture = show
        cell.picture = show && !c.isGroup ? store?.buddyPicture(isFromMe: false, handle: c.participantHandles.first) : nil
    }

    private func configurePins(_ view: SidebarPinsView) {
        view.conversations = pinned
        view.pictures = pinned.map { c in
            c.isGroup ? nil : store?.buddyPicture(isFromMe: false, handle: c.participantHandles.first)
        }
        view.selectedID = selectedID
        view.activeFraction = activeFader.value
    }

    /// The text inset changes; row heights don't. No motion.
    private func buddyPicturesChanged() {
        endRowsAnimation()
        isSyncingSelection = true
        tableView.reloadData()
        syncSelection(scroll: false)
        isSyncingSelection = false
    }

    private func refreshVisiblePictures() {
        tableView.enumerateAvailableRowViews { rowView, row in
            guard row < items.count else { return }
            if let cell = rowView.view(atColumn: 0) as? SidebarCell, let c = items[row].conversation {
                configurePicture(cell, c)
            } else if let pins = rowView.view(atColumn: 0) as? SidebarPinsView {
                configurePins(pins)
            }
        }
    }

    private func applyAppearance() {
        let bg = LionTheme.palette(for: tableView.effectiveAppearance).sidebarBackground
        tableView.backgroundColor = bg
        scrollView.backgroundColor = bg
    }

    /// Blue ⇄ graphite selection crossfade as the window becomes or resigns key.
    private func applyActiveFraction() {
        let value = activeFader.value
        tableView.enumerateAvailableRowViews { rowView, _ in
            (rowView as? SidebarRowView)?.activeFraction = value
        }
        pinsView?.activeFraction = value
    }

    private func update(rows list: [Conversation], pinned newPinned: [Conversation], header: String) {
        var newItems: [SidebarItem] = newPinned.isEmpty ? [] : [.pins]
        newItems.append(.header)
        newItems += list.map(SidebarItem.conversation)
        guard newItems != items || newPinned != pinned || header != headerTitle else { return }
        let isFirstLoad = items.isEmpty
        let searchText = store?.searchText ?? ""
        let scope = store?.scope
        let isFilter = searchText != lastSearchText || scope != lastScope
        lastSearchText = searchText
        lastScope = scope
        endRowsAnimation()
        let before = isFirstLoad ? [:] : snapshotVisibleRows()
        items = newItems
        pinned = newPinned
        headerTitle = header
        isSyncingSelection = true
        tableView.reloadData()
        syncSelection(scroll: false)
        isSyncingSelection = false
        if !before.isEmpty { animateRows(from: before, isFilter: isFilter) }
        // Start with keyboard focus in the list so the arrow keys work right away.
        if isFirstLoad, !list.isEmpty || !newPinned.isEmpty, let window = tableView.window,
           window.firstResponder === window || window.firstResponder == nil {
            window.makeFirstResponder(tableView)
        }
    }

    // MARK: Row motion (reorder, new rows, filtering, updated text)

    private static let headerKey = Int64.min
    private static let pinsKey = Int64.min + 1

    private func key(_ item: SidebarItem) -> Int64 {
        switch item {
        case .pins: return Self.pinsKey
        case .header: return Self.headerKey
        case .conversation(let c): return c.id
        }
    }

    /// Pictures of the rows on screen, keyed by conversation ID.
    private func snapshotVisibleRows() -> [Int64: SidebarRowsOverlay.Snap] {
        guard tableView.window != nil, !LionMotion.isDisabled else { return [:] }
        tableView.layoutSubtreeIfNeeded()
        let visible = tableView.visibleRect
        var out: [Int64: SidebarRowsOverlay.Snap] = [:]
        tableView.enumerateAvailableRowViews { rowView, row in
            guard rowView.frame.intersects(visible), row < items.count,
                  let image = rowView.lionSnapshot() else { return }
            out[key(items[row])] = .init(image: image, frame: rowView.frame)
        }
        return out
    }

    private func animateRows(from before: [Int64: SidebarRowsOverlay.Snap], isFilter: Bool) {
        let after = snapshotVisibleRows()
        let moved = before.contains { key, snap in after[key].map { $0.frame.minY != snap.frame.minY } ?? false }
        let appeared = after.keys.contains { before[$0] == nil }
        let vanished = before.keys.contains { after[$0] == nil }
        guard moved || appeared || vanished || !after.isEmpty else { return }
        let overlay = SidebarRowsOverlay(before: before, after: after, reduceMotion: LionMotion.reduceMotion,
                                         background: LionTheme.palette(for: tableView.effectiveAppearance).sidebarBackground)
        overlay.frame = tableView.visibleRect
        tableView.addSubview(overlay, positioned: .above, relativeTo: nil)
        let duration = isFilter ? LionMotion.sidebarFilter : (moved ? LionMotion.sidebarMove : LionMotion.sidebarFilter)
        let tween = LionTween.run(duration: duration, curve: moved && !isFilter ? .easeInOut : .easeOut, update: { [weak self] t in
            guard let self else { return }
            overlay.frame = self.tableView.visibleRect
            if self.tableView.subviews.last !== overlay {
                self.tableView.addSubview(overlay, positioned: .above, relativeTo: nil)
            }
            overlay.progress = t
        }, completion: { [weak self] in
            self?.endRowsAnimation()
        })
        if !tween.isFinished { rowsAnimation = (overlay, tween) } else { overlay.removeFromSuperview() }
    }

    private func endRowsAnimation() {
        guard let animation = rowsAnimation else { return }
        rowsAnimation = nil
        animation.tween.cancel()
        animation.overlay.removeFromSuperview()
    }

    private func update(selectedID id: Int64?) {
        guard id != selectedID else { return }
        selectedID = id
        // Selection is instant, as in Lion's source lists.
        endRowsAnimation()
        pinsView?.selectedID = id
        isSyncingSelection = true
        syncSelection(scroll: true)
        isSyncingSelection = false
    }

    private func syncSelection(scroll: Bool) {
        if let id = selectedID, let row = items.firstIndex(where: { $0.conversation?.id == id }) {
            if tableView.selectedRow != row {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            if scroll { tableView.scrollRowToVisible(row) }
        } else {
            tableView.deselectAll(nil)
            if scroll, let id = selectedID, pinned.contains(where: { $0.id == id }) { tableView.scrollRowToVisible(0) }
        }
    }

    // MARK: Data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch items[row] {
        case .pins: return SidebarPinsView.height(count: pinned.count)
        case .header: return Self.headerHeight
        case .conversation: return Self.rowHeight
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { items[row].conversation != nil }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("SidebarRow")
        let view = tableView.makeView(withIdentifier: id, owner: nil) as? SidebarRowView ?? SidebarRowView()
        view.identifier = id
        view.activeFraction = activeFader.value
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch items[row] {
        case .pins:
            let id = NSUserInterfaceItemIdentifier("SidebarPins")
            let view = tableView.makeView(withIdentifier: id, owner: nil) as? SidebarPinsView ?? SidebarPinsView()
            view.identifier = id
            view.onSelect = { [weak self] c in self?.selectFromPins(c) }
            view.onUnpin = { [weak self] c in self?.store?.setPinned(false, c) }
            configurePins(view)
            pinsView = view
            return view
        case .header:
            let id = NSUserInterfaceItemIdentifier("SidebarHeader")
            let view = tableView.makeView(withIdentifier: id, owner: nil) as? SidebarHeaderCell ?? SidebarHeaderCell()
            view.identifier = id
            view.title = headerTitle
            return view
        case .conversation(let c):
            let id = NSUserInterfaceItemIdentifier("SidebarCell")
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? SidebarCell ?? SidebarCell()
            cell.identifier = id
            configurePicture(cell, c)
            cell.conversation = c
            return cell
        }
    }

    private func selectFromPins(_ c: Conversation) {
        endRowsAnimation()
        // Keep the keyboard in the list, like clicking a row does.
        if let window = tableView.window, window.firstResponder !== tableView { window.makeFirstResponder(tableView) }
        selectedID = c.id
        pinsView?.selectedID = c.id
        isSyncingSelection = true
        tableView.deselectAll(nil)
        isSyncingSelection = false
        store?.select(c.id)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection else { return }
        endRowsAnimation()
        let row = tableView.selectedRow
        guard row >= 0, row < items.count, let c = items[row].conversation else { return }
        selectedID = c.id
        pinsView?.selectedID = c.id
        store?.select(c.id)
    }

    // MARK: Context menu (Pin / Unpin)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard row >= 0, row < items.count, let c = items[row].conversation, let store else { return }
        addPinItem(to: menu, for: c, store: store)
    }

    fileprivate func addPinItem(to menu: NSMenu, for c: Conversation, store: AppStore) {
        let pinnedNow = store.isPinned(c)
        guard pinnedNow || c.senderCategory != .spam else { return }
        let item = NSMenuItem(title: pinnedNow ? "Unpin" : "Pin", action: #selector(togglePin(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = c.id
        menu.addItem(item)
    }

    @objc private func togglePin(_ sender: NSMenuItem) {
        guard let store, let id = sender.representedObject as? Int64,
              let c = store.conversations.first(where: { $0.id == id }) else { return }
        store.setPinned(!store.isPinned(c), c)
    }
}

final class SidebarTableView: NSTableView {
    var onAppearanceChange: () -> Void = {}
    var onWindowChange: (NSWindow?) -> Void = { _ in }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange(window)
    }
}

/// Full-width Lion selection: blue gradient (graphite-blue when the window is inactive).
final class SidebarRowView: NSTableRowView {
    override var isSelected: Bool {
        didSet { if isSelected != oldValue { subviews.forEach { $0.needsDisplay = true } } }
    }

    /// Mail-style hairline between rows (not under the header or the pins, not when selected).
    override func drawBackground(in dirtyRect: NSRect) {
        guard !isSelected, !(subviews.first is SidebarHeaderCell), !(subviews.first is SidebarPinsView) else { return }
        LionTheme.palette(for: effectiveAppearance).sidebarSeparator.setFill()
        NSRect(x: 0, y: isFlipped ? bounds.maxY - 1 : 0, width: bounds.width, height: 1).fill()
    }

    /// 1 = window active (blue), 0 = inactive (graphite); in between while crossfading.
    var activeFraction: CGFloat = 1 {
        didSet { if activeFraction != oldValue && isSelected { needsDisplay = true } }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let a = activeFraction
        if a < 1 { drawSelection(active: false) }
        guard a > 0, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.setAlpha(a)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        drawSelection(active: true)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private func drawSelection(active: Bool) {
        let p = LionTheme.palette(for: effectiveAppearance)
        let r = bounds
        (active ? p.selection : p.selectionInactive).drawVertical(in: r, flipped: isFlipped)
        (active ? p.selectionTopLine : p.selectionInactiveTopLine).setFill()
        NSRect(x: 0, y: isFlipped ? r.minY : r.maxY - 1, width: r.width, height: 1).fill()
        (active ? p.selectionBottomLine : p.selectionInactiveBottomLine).setFill()
        NSRect(x: 0, y: isFlipped ? r.maxY - 1 : r.minY, width: r.width, height: 1).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { isSelected ? .emphasized : .normal }
}

/// Stand-in for the sidebar's rows while the list changes: rows glide from their old to their
/// new places (a conversation with a new message rising to the top), changed text crossfades,
/// new rows fade and slide in, removed ones fade out. Reduce Motion: a plain crossfade.
final class SidebarRowsOverlay: NSView {
    struct Snap {
        let image: NSImage
        let frame: NSRect
    }

    private let before: [Int64: Snap]
    private let after: [Int64: Snap]
    private let reduceMotion: Bool
    private let background: NSColor
    /// Rows that travel furthest are drawn last, so the one rising to the top passes over the others.
    private let order: [Int64]
    var progress: CGFloat = 0 { didSet { needsDisplay = true } }

    init(before: [Int64: Snap], after: [Int64: Snap], reduceMotion: Bool, background: NSColor) {
        self.before = before
        self.after = after
        self.reduceMotion = reduceMotion
        self.background = background
        let keys = Set(before.keys).union(after.keys)
        // Removed rows underneath, then new ones, then rows by distance travelled.
        func rank(_ k: Int64) -> (Int, CGFloat, Int64) {
            switch (before[k], after[k]) {
            case let (b?, a?): return (2, abs(a.frame.minY - b.frame.minY), k)
            case (nil, _?): return (1, 0, k)
            default: return (0, 0, k)
            }
        }
        order = keys.sorted { rank($0) < rank($1) }
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        bounds.fill()
        let t = progress
        // Coordinates: snapshots carry table coordinates; this view sits at the visible rect.
        // Each row is drawn as an opaque picture (background + row) faded as one layer, so
        // identical pictures crossfade without any dip and moving rows cover what they pass.
        let ctx = NSGraphicsContext.current?.cgContext
        func draw(_ snap: Snap, y: CGFloat, alpha: CGFloat) {
            guard alpha > 0, let ctx else { return }
            let r = NSRect(x: snap.frame.minX - frame.minX, y: y - frame.minY,
                           width: snap.frame.width, height: snap.frame.height)
            ctx.saveGState()
            ctx.setAlpha(alpha)
            ctx.beginTransparencyLayer(in: r, auxiliaryInfo: nil)
            background.setFill()
            r.fill()
            snap.image.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
        for key in order {
            let old = before[key], new = after[key]
            if reduceMotion {
                if let old { draw(old, y: old.frame.minY, alpha: 1 - t) }
                if let new { draw(new, y: new.frame.minY, alpha: t) }
                continue
            }
            switch (old, new) {
            case let (old?, new?):
                let y = old.frame.minY + (new.frame.minY - old.frame.minY) * t
                // The new picture, with the old one fading out over it (changed text crossfades).
                draw(new, y: y, alpha: 1)
                draw(old, y: y, alpha: 1 - t)
            case let (nil, new?):
                draw(new, y: new.frame.minY - (1 - t) * 8, alpha: t)
            case let (old?, nil):
                draw(old, y: old.frame.minY, alpha: 1 - t)
            case (nil, nil):
                break
            }
        }
    }
}

/// "KNOWN SENDERS", "SPAM"… — the small, bold, uppercase source-list header.
final class SidebarHeaderCell: NSView {
    var title = "CONVERSATIONS" { didSet { if title != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let p = LionTheme.palette(for: effectiveAppearance)
        let str = NSAttributedString(string: title, attributes: [
            .font: LionFont.bold(11),
            .foregroundColor: p.sidebarHeader,
            .shadow: p.sidebarShadow.nsShadow,
            .kern: 0.2,
        ])
        str.draw(at: NSPoint(x: 10, y: bounds.height - str.size().height - 5))
    }
}

final class SidebarCell: NSView {
    var conversation: Conversation? { didSet { needsDisplay = true; updateAccessibility() } }
    var showsPicture = false { didSet { if showsPicture != oldValue { needsDisplay = true } } }
    var picture: NSImage? { didSet { if picture !== oldValue { needsDisplay = true } } }
    static let pictureX: CGFloat = 10

    override var isFlipped: Bool { true }

    private var isSelected: Bool { (superview as? NSTableRowView)?.isSelected ?? false }

    private func updateAccessibility() {
        guard let c = conversation else { return }
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
        setAccessibilityLabel("\(c.title), \(LionDateFormat.sidebar(c.lastMessageDate))")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let c = conversation else { return }
        let p = LionTheme.palette(for: effectiveAppearance)
        let selected = isSelected
        let shadow = selected ? p.selectedTextShadow.nsShadow : p.sidebarShadow.nsShadow
        var left: CGFloat = 14
        let right: CGFloat = 10
        if showsPicture, let ctx = NSGraphicsContext.current?.cgContext {
            let s = BuddyMetrics.size
            let r = NSRect(x: Self.pictureX, y: floor((bounds.height - s) / 2), width: s, height: s)
            BuddyPicture.draw(picture, isGroup: c.isGroup, in: r, palette: p, ctx: ctx)
            left = r.maxX + 9
        }

        let date = NSAttributedString(string: LionDateFormat.sidebar(c.lastMessageDate), attributes: [
            .font: LionFont.regular(11),
            .foregroundColor: selected ? p.selectedText : p.sidebarDate,
            .shadow: shadow,
        ])
        let dateSize = date.size()
        let dateX = bounds.width - right - dateSize.width
        date.draw(at: NSPoint(x: dateX, y: 7))

        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        let name = NSAttributedString(string: c.title, attributes: [
            .font: LionFont.bold(12),
            .foregroundColor: selected ? p.selectedText : p.sidebarName,
            .shadow: shadow,
            .paragraphStyle: truncating,
        ])
        name.draw(with: NSRect(x: left, y: 5, width: dateX - left - 6, height: 17),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

        let wrapping = NSMutableParagraphStyle()
        wrapping.lineBreakMode = .byWordWrapping
        let previewText = c.lastMessagePreview.replacingOccurrences(of: "\n", with: " ")
        let preview = NSAttributedString(string: previewText, attributes: [
            .font: LionFont.regular(11),
            .foregroundColor: selected ? p.selectedText.withAlphaComponent(0.9) : p.sidebarPreview,
            .shadow: shadow,
            .paragraphStyle: wrapping,
        ])
        preview.draw(with: NSRect(x: left, y: 21, width: bounds.width - left - right, height: 28),
                     options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

struct SidebarRepresentable: NSViewRepresentable {
    let store: AppStore

    func makeCoordinator() -> SidebarController { SidebarController(store: store) }

    func makeNSView(context: Context) -> LionScrollView { context.coordinator.scrollView }

    func updateNSView(_ nsView: LionScrollView, context: Context) {}
}
