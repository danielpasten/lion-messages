import AppKit
import Combine
import SwiftUI

/// Lion's scope bar (as under Finder's search field) above the conversation list: recessed
/// buttons that pick Known Senders, Unknown Senders or Spam.
final class SidebarScopeBar: LionView {
    static let height: CGFloat = 26

    struct Item: Equatable {
        var scope: SidebarScope
        var title: String
        var count: Int?
    }

    var items: [Item] = [] { didSet { if items != oldValue { needsDisplay = true; updateAccessibility() } } }
    var selected: SidebarScope = .known { didSet { if selected != oldValue { needsDisplay = true; updateAccessibility() } } }
    var onSelect: (SidebarScope) -> Void = { _ in }
    private var pressed: SidebarScope? { didSet { if pressed != oldValue { needsDisplay = true } } }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Layout

    private static let font = LionFont.bold(11)
    private static let countFont = LionFont.regular(10)

    private func label(_ item: Item, selected: Bool, palette p: LionPalette) -> NSAttributedString {
        let text = NSMutableAttributedString(string: item.title, attributes: [
            .font: Self.font,
            .foregroundColor: selected ? NSColor.white : p.sidebarHeader,
            .shadow: selected ? p.selectedTextShadow.nsShadow : p.sidebarShadow.nsShadow,
        ])
        if let count = item.count, count > 0 {
            text.append(NSAttributedString(string: "  \(count)", attributes: [
                .font: Self.countFont,
                .foregroundColor: selected ? NSColor(white: 1, alpha: 0.8) : p.sidebarDate,
                .shadow: selected ? p.selectedTextShadow.nsShadow : p.sidebarShadow.nsShadow,
            ]))
        }
        return text
    }

    private func buttonRects() -> [NSRect] {
        let p = palette
        var x: CGFloat = 8
        let h: CGFloat = 18
        let y = ((bounds.height - 1 - h) / 2).rounded()
        return items.map { item in
            let w = ceil(label(item, selected: false, palette: p).size().width) + 18
            defer { x += w + 3 }
            return NSRect(x: x, y: y, width: w, height: h)
        }
    }

    // MARK: Drawing

    private var barGradient: LionGradient {
        palette.isDark
            ? LionGradient(stops: [(NSColor(hex: 0x3c3f44), 0), (NSColor(hex: 0x313338), 1)])
            : LionGradient(stops: [(NSColor(hex: 0xe9e9e9), 0), (NSColor(hex: 0xd3d3d3), 1)])
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = palette
        barGradient.drawVertical(in: bounds, flipped: true)
        NSColor(white: 1, alpha: p.isDark ? 0.07 : 0.6).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        (p.isDark ? NSColor(hex: 0x1c1e21) : NSColor(hex: 0xa5a5a5)).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()

        for (item, rect) in zip(items, buttonRects()) {
            let isOn = item.scope == selected
            let isPressed = item.scope == pressed
            if isOn || isPressed {
                // Recessed: a dark translucent pill with an inner shadow and a highlight under it.
                let shape = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
                NSColor(white: 1, alpha: p.isDark ? 0.08 : 0.55).setStroke()
                let under = NSBezierPath(roundedRect: rect.offsetBy(dx: 0, dy: 1), xRadius: rect.height / 2, yRadius: rect.height / 2)
                under.lineWidth = 1
                under.stroke()
                let top: CGFloat = isOn ? (p.isDark ? 0.55 : 0.42) : 0.2
                LionGradient(stops: [(NSColor(white: 0, alpha: top), 0), (NSColor(white: 0, alpha: top * 0.7), 1)])
                    .drawVertical(in: shape, flipped: true)
                NSGraphicsContext.saveGraphicsState()
                shape.addClip()
                let inner = NSShadow()
                inner.shadowColor = NSColor(white: 0, alpha: 0.5)
                inner.shadowBlurRadius = 2
                inner.shadowOffset = NSSize(width: 0, height: -1)
                inner.set()
                NSColor(white: 0, alpha: 0.3).setStroke()
                let ring = NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: rect.height / 2 + 1, yRadius: rect.height / 2 + 1)
                ring.lineWidth = 2
                ring.stroke()
                NSGraphicsContext.restoreGraphicsState()
            }
            let str = label(item, selected: isOn, palette: p)
            let size = str.size()
            str.draw(at: NSPoint(x: (rect.midX - size.width / 2).rounded(), y: rect.midY - size.height / 2))
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let rects = buttonRects()
        func hit(_ e: NSEvent) -> SidebarScope? {
            let point = convert(e.locationInWindow, from: nil)
            return zip(items, rects).first { $0.1.contains(point) }?.0.scope
        }
        guard let start = hit(event) else { return }
        pressed = start
        var inside = true
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            inside = hit(next) == start
            pressed = inside ? start : nil
            if next.type == .leftMouseUp { break }
        }
        pressed = nil
        if inside { onSelect(start) }
    }

    // MARK: Accessibility

    private final class ScopeElement: NSAccessibilityElement {
        var onPress: () -> Void = {}
        override func accessibilityPerformPress() -> Bool { onPress(); return true }
    }

    private func updateAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("Sender Lists")
        let rects = buttonRects()
        setAccessibilityChildren(zip(items, rects).map { item, rect in
            let element = ScopeElement()
            element.onPress = { [weak self] in self?.onSelect(item.scope) }
            element.setAccessibilityRole(.radioButton)
            element.setAccessibilityLabel(item.count.map { "\(item.title), \($0)" } ?? item.title)
            element.setAccessibilityValue(item.scope == selected ? 1 : 0)
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(rect)
            return element
        })
    }

    override func layout() {
        super.layout()
        updateAccessibility()
    }
}

extension SidebarScope {
    /// The scope bar's short label (the bar is only as wide as the sidebar).
    func shortLabel(filteringUnknown: Bool) -> String {
        switch self {
        case .known: return filteringUnknown ? "Known" : "All Messages"
        case .unknown: return "Unknown"
        case .spam: return "Spam"
        }
    }
}

struct SidebarScopeBarRepresentable: NSViewRepresentable {
    let store: AppStore

    final class Coordinator {
        var cancellables: Set<AnyCancellable> = []
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SidebarScopeBar {
        let bar = SidebarScopeBar()
        bar.onSelect = { [weak store] scope in store?.setScope(scope) }
        store.$scope
            .combineLatest(store.$scopeCounts, store.$filtersUnknownSenders)
            .receive(on: DispatchQueue.main)
            .sink { [weak bar] scope, counts, filtering in
                guard let bar else { return }
                bar.items = SidebarScope.scopes(filteringUnknown: filtering).map { s in
                    // Counts only where they help: how much is waiting in the filtered lists.
                    SidebarScopeBar.Item(scope: s, title: s.shortLabel(filteringUnknown: filtering),
                                         count: s == .known ? nil : counts[s] ?? 0)
                }
                bar.selected = scope
            }
            .store(in: &context.coordinator.cancellables)
        return bar
    }

    func updateNSView(_ nsView: SidebarScopeBar, context: Context) {}
}
