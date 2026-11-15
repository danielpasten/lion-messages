import AppKit
import MessagesModel

/// Pinned conversations at the top of the sidebar, as in Messages, drawn the Lion way: large
/// iChat buddy pictures in a three-column icon grid, selected like a Finder icon (a soft
/// rounded backdrop behind the picture and a blue pill behind the name).
final class SidebarPinsView: NSView {
    static let columns = 3
    static let pictureSize: CGFloat = 52
    static let tileHeight: CGFloat = 84
    static let topInset: CGFloat = 12
    static let bottomInset: CGFloat = 4
    static let sideInset: CGFloat = 8

    static func height(count: Int) -> CGFloat {
        let rows = (count + columns - 1) / columns
        return topInset + CGFloat(rows) * tileHeight + bottomInset
    }

    var conversations: [Conversation] = [] {
        didSet { if conversations != oldValue { needsDisplay = true; updateAccessibility() } }
    }
    /// Buddy pictures, parallel to `conversations` (nil: the generic silhouette).
    var pictures: [NSImage?] = [] { didSet { needsDisplay = true } }
    var selectedID: Int64? { didSet { if selectedID != oldValue { needsDisplay = true; updateAccessibility() } } }
    /// 1 = window active (blue selection), 0 = inactive (graphite).
    var activeFraction: CGFloat = 1 { didSet { if activeFraction != oldValue { needsDisplay = true } } }
    var onSelect: (Conversation) -> Void = { _ in }
    var onUnpin: (Conversation) -> Void = { _ in }

    private var pressedIndex: Int? { didSet { if pressedIndex != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Geometry

    private func tileRect(_ index: Int) -> NSRect {
        let width = (bounds.width - 2 * Self.sideInset) / CGFloat(Self.columns)
        let row = index / Self.columns, col = index % Self.columns
        return NSRect(x: Self.sideInset + CGFloat(col) * width, y: Self.topInset + CGFloat(row) * Self.tileHeight,
                      width: width, height: Self.tileHeight)
    }

    private func pictureRect(in tile: NSRect) -> NSRect {
        let s = Self.pictureSize
        return NSRect(x: (tile.midX - s / 2).rounded(), y: tile.minY + 6, width: s, height: s)
    }

    private func index(at point: NSPoint) -> Int? {
        conversations.indices.first { tileRect($0).insetBy(dx: 2, dy: 0).contains(point) }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let p = LionTheme.palette(for: effectiveAppearance)
        for (i, c) in conversations.enumerated() {
            let tile = tileRect(i)
            guard tile.intersects(dirtyRect) else { continue }
            let pic = pictureRect(in: tile)
            let selected = c.id == selectedID
            if selected || pressedIndex == i {
                // Finder's icon selection: a translucent rounded square behind the picture.
                let backdrop = NSBezierPath(roundedRect: pic.insetBy(dx: -5, dy: -5), xRadius: 6, yRadius: 6)
                NSColor(white: p.isDark ? 1 : 0, alpha: selected ? (p.isDark ? 0.16 : 0.13) : 0.08).setFill()
                backdrop.fill()
            }
            BuddyPicture.draw(i < pictures.count ? pictures[i] : nil, isGroup: c.isGroup, in: pic, palette: p, ctx: ctx)
            drawName(Self.shortName(c), below: pic, in: tile, selected: selected, palette: p)
        }
    }

    private func drawName(_ name: String, below pic: NSRect, in tile: NSRect, selected: Bool, palette p: LionPalette) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = .center
        let shadow = selected ? p.selectedTextShadow.nsShadow : p.sidebarShadow.nsShadow
        let attrs: [NSAttributedString.Key: Any] = [
            .font: selected ? LionFont.bold(11) : LionFont.regular(11),
            .foregroundColor: selected ? p.selectedText : p.sidebarName,
            .shadow: shadow,
            .paragraphStyle: style,
        ]
        let str = NSAttributedString(string: name, attributes: attrs)
        let maxWidth = tile.width - 8
        let textWidth = min(ceil(str.size().width), maxWidth - 12)
        let textHeight: CGFloat = 15
        let y = pic.maxY + 8
        if selected {
            // A blue (graphite when inactive) pill behind the name.
            let pill = NSRect(x: (tile.midX - textWidth / 2 - 6).rounded(), y: y - 1, width: textWidth + 12, height: textHeight + 2)
            let path = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2)
            if activeFraction < 1 { p.selectionInactive.drawVertical(in: path, flipped: true) }
            if activeFraction > 0, let ctx = NSGraphicsContext.current?.cgContext {
                ctx.saveGState()
                ctx.setAlpha(activeFraction)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                p.selection.drawVertical(in: path, flipped: true)
                ctx.endTransparencyLayer()
                ctx.restoreGState()
            }
        }
        str.draw(with: NSRect(x: tile.midX - textWidth / 2, y: y, width: textWidth, height: textHeight),
                 options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// First names for people (as Messages labels pins); groups, numbers and addresses in full.
    static func shortName(_ c: Conversation) -> String {
        let title = c.title
        guard !c.isGroup, !title.contains("@"), let first = title.first,
              first.isLetter else { return title }
        return title.split(separator: " ").first.map(String.init) ?? title
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard let start = index(at: convert(event.locationInWindow, from: nil)) else { return }
        pressedIndex = start
        var inside = true
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            inside = index(at: convert(next.locationInWindow, from: nil)) == start
            pressedIndex = inside ? start : nil
            if next.type == .leftMouseUp { break }
        }
        pressedIndex = nil
        if inside, start < conversations.count { onSelect(conversations[start]) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let i = index(at: convert(event.locationInWindow, from: nil)) else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: "Unpin", action: #selector(unpin(_:)), keyEquivalent: "")
        item.target = self
        item.tag = i
        menu.addItem(item)
        return menu
    }

    @objc private func unpin(_ sender: NSMenuItem) {
        guard sender.tag < conversations.count else { return }
        onUnpin(conversations[sender.tag])
    }

    // MARK: Accessibility

    /// A tile VoiceOver can press.
    private final class TileElement: NSAccessibilityElement {
        var onPress: () -> Void = {}
        override func accessibilityPerformPress() -> Bool { onPress(); return true }
    }

    private var tileElements: [NSAccessibilityElement] = []

    private func updateAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Pinned Conversations")
        tileElements = conversations.enumerated().map { i, c in
            let element = TileElement()
            element.onPress = { [weak self] in self?.onSelect(c) }
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(c.title)
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(tileRect(i))
            element.setAccessibilitySelected(c.id == selectedID)
            return element
        }
        setAccessibilityChildren(tileElements)
    }

    override func layout() {
        super.layout()
        updateAccessibility()
    }
}
