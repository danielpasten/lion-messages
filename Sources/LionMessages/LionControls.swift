import AppKit

/// Flipped view that redraws itself when the appearance or the window's key state changes.
class LionView: NSView {
    override var isFlipped: Bool { true }

    var palette: LionPalette { LionTheme.palette(for: effectiveAppearance) }
    /// 1 = window is key, 0 = not; crossfades in between (Lion's quick active/inactive change).
    var activeFraction: CGFloat { activeFader.value }
    var isWindowActive: Bool { activeFraction > 0.5 }

    private let activeFader = LionActiveFader()

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceDidChange()
        needsDisplay = true
    }

    /// Subclasses override to recolor subviews.
    func appearanceDidChange() {}

    /// Subclasses override to react to the window becoming/resigning key (called every frame
    /// of the crossfade).
    func windowKeyStateDidChange() { needsDisplay = true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        activeFader.onChange = { [weak self] in self?.windowKeyStateDidChange() }
        activeFader.attach(to: window)
    }
}

// MARK: - Overlay scrollers (Lion introduced them)

final class LionScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        let knob = rect(for: .knob)
        guard !knob.isEmpty else { return }
        let thickness: CGFloat = 7
        let r: NSRect
        if bounds.height >= bounds.width {
            r = NSRect(x: bounds.maxX - thickness - 2, y: knob.minY + 2, width: thickness, height: knob.height - 4)
        } else {
            r = NSRect(x: knob.minX + 2, y: bounds.maxY - thickness - 2, width: knob.width - 4, height: thickness)
        }
        LionTheme.palette(for: effectiveAppearance).scrollerKnob.setFill()
        NSBezierPath(roundedRect: r, xRadius: thickness / 2, yRadius: thickness / 2).fill()
    }
}

/// NSScrollView that keeps Lion overlay scrollers even if the user prefers legacy ones.
final class LionScrollView: NSScrollView {
    private var styleObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        verticalScroller = LionScroller()
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        borderType = .noBorder
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsetsZero
        styleObserver = NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.scrollerStyle = .overlay }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { styleObserver.map(NotificationCenter.default.removeObserver) }

    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }
}

// MARK: - Glyphs (Lion used small monochrome glyphs, not SF Symbols)

enum LionGlyph {
    case refresh, compose, paperclip, phone, video, sidebar

    /// Stroked outline, plus an optional filled part (arrow heads).
    func paths(in r: NSRect) -> (stroke: NSBezierPath, fill: NSBezierPath?) {
        let p = path(in: r)
        guard self == .refresh else { return (p, nil) }
        let c = NSPoint(x: r.midX, y: r.midY)
        let radius = min(r.width, r.height) / 2 - 1.5
        let angle = -70 * CGFloat.pi / 180
        let tip = NSPoint(x: c.x + radius * cos(angle), y: c.y + radius * sin(angle))
        let head = NSBezierPath()
        head.move(to: NSPoint(x: tip.x + 4.2, y: tip.y - 0.2))
        head.line(to: NSPoint(x: tip.x - 1.6, y: tip.y - 4.2))
        head.line(to: NSPoint(x: tip.x - 1.2, y: tip.y + 3.6))
        head.close()
        return (p, head)
    }

    private func path(in r: NSRect) -> NSBezierPath {
        let p = NSBezierPath()
        let c = NSPoint(x: r.midX, y: r.midY)
        switch self {
        case .refresh:
            // Flipped coordinates: circular arrow, open at the top right.
            let radius = min(r.width, r.height) / 2 - 1.5
            p.appendArc(withCenter: c, radius: radius, startAngle: -70, endAngle: 230, clockwise: false)
            p.lineWidth = 1.8
        case .compose:
            // A sheet of paper with a pencil across it.
            let sheet = NSRect(x: r.minX + 1, y: r.minY + 3, width: r.width - 5, height: r.height - 4)
            let paper = NSBezierPath(roundedRect: sheet, xRadius: 1.5, yRadius: 1.5)
            paper.lineWidth = 1.5
            p.append(paper)
            let pencil = NSBezierPath()
            pencil.move(to: NSPoint(x: r.maxX - 0.5, y: r.minY + 2.5))
            pencil.line(to: NSPoint(x: r.maxX - 2.5, y: r.minY + 0.5))
            pencil.line(to: NSPoint(x: r.midX - 2.5, y: r.midY + 3))
            pencil.line(to: NSPoint(x: r.midX - 3.5, y: r.midY + 6))
            pencil.line(to: NSPoint(x: r.midX - 0.5, y: r.midY + 5))
            pencil.close()
            p.append(pencil)
        case .sidebar:
            // A window with a list down its left side.
            let frame = NSRect(x: r.minX + 0.75, y: r.minY + 2.25, width: r.width - 1.5, height: r.height - 4.5)
            p.append(NSBezierPath(roundedRect: frame, xRadius: 1.5, yRadius: 1.5))
            let split = (frame.minX + frame.width * 0.38).rounded() + 0.5
            p.move(to: NSPoint(x: split, y: frame.minY))
            p.line(to: NSPoint(x: split, y: frame.maxY))
            for i in 0..<3 {
                let y = frame.minY + 3 + CGFloat(i) * 2.5
                p.move(to: NSPoint(x: frame.minX + 2, y: y))
                p.line(to: NSPoint(x: split - 2, y: y))
            }
            p.lineWidth = 1.3
        case .phone:
            // An old-fashioned handset, earpiece up-left, mouthpiece down-right.
            let handset = NSBezierPath()
            handset.move(to: NSPoint(x: r.minX + 1.5, y: r.minY + 3.2))
            handset.curve(to: NSPoint(x: r.maxX - 3.2, y: r.maxY - 1.5),
                          controlPoint1: NSPoint(x: r.minX + 1.2, y: r.midY + 3),
                          controlPoint2: NSPoint(x: r.midX - 3, y: r.maxY - 1.2))
            handset.line(to: NSPoint(x: r.maxX - 0.8, y: r.maxY - 3.6))
            handset.line(to: NSPoint(x: r.maxX - 3.6, y: r.maxY - 6.6))
            handset.line(to: NSPoint(x: r.maxX - 5.8, y: r.maxY - 5.2))
            handset.curve(to: NSPoint(x: r.minX + 5.2, y: r.minY + 5.8),
                          controlPoint1: NSPoint(x: r.midX - 1, y: r.midY + 2.5),
                          controlPoint2: NSPoint(x: r.midX - 2.5, y: r.midY + 1))
            handset.line(to: NSPoint(x: r.minX + 6.6, y: r.minY + 3.6))
            handset.line(to: NSPoint(x: r.minX + 3.6, y: r.minY + 0.8))
            handset.close()
            handset.lineWidth = 1.4
            p.append(handset)
            p.lineWidth = 1.4
        case .video:
            // A camera body with its lens hood to the right.
            let body = NSBezierPath(roundedRect: NSRect(x: r.minX + 0.5, y: r.midY - 4, width: r.width - 6, height: 8),
                                    xRadius: 1.8, yRadius: 1.8)
            body.lineWidth = 1.5
            p.append(body)
            let hood = NSBezierPath()
            hood.move(to: NSPoint(x: r.maxX - 5.5, y: r.midY - 1.2))
            hood.line(to: NSPoint(x: r.maxX - 0.5, y: r.midY - 3.6))
            hood.line(to: NSPoint(x: r.maxX - 0.5, y: r.midY + 3.6))
            hood.line(to: NSPoint(x: r.maxX - 5.5, y: r.midY + 1.2))
            hood.close()
            p.append(hood)
            p.lineWidth = 1.5
        case .paperclip:
            // A classic two-loop paperclip, drawn upright around the origin, then tilted 45°.
            let clip = NSBezierPath()
            clip.move(to: NSPoint(x: 0, y: -2.6))
            clip.line(to: NSPoint(x: 0, y: 3.4))
            clip.appendArc(withCenter: NSPoint(x: -1.15, y: 3.4), radius: 1.15, startAngle: 0, endAngle: 180, clockwise: false)
            clip.line(to: NSPoint(x: -2.3, y: -3.9))
            clip.appendArc(withCenter: NSPoint(x: 0, y: -3.9), radius: 2.3, startAngle: 180, endAngle: 360, clockwise: false)
            clip.line(to: NSPoint(x: 2.3, y: 5.2))
            var t = AffineTransform(translationByX: c.x, byY: c.y)
            t.rotate(byDegrees: 45)
            t.scale(1.12)
            clip.transform(using: t)
            clip.lineWidth = 1.5
            p.append(clip)
            p.lineWidth = 1.5
        }
        return p
    }
}

// MARK: - Textured rounded toolbar button

final class LionTexturedButton: LionView {
    var glyph: LionGlyph
    var action: () -> Void
    var isEnabled = true {
        didSet { if isEnabled != oldValue { needsDisplay = true; setAccessibilityEnabled(isEnabled) } }
    }
    private var pressed = false { didSet { needsDisplay = true } }

    init(glyph: LionGlyph, toolTip: String, action: @escaping () -> Void) {
        self.glyph = glyph
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: 34, height: 23))
        self.toolTip = toolTip
        setAccessibilityRole(.button)
        setAccessibilityLabel(toolTip)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: 34, height: 23) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let p = palette
        let body = NSRect(x: 0.5, y: 0.5, width: bounds.width - 1, height: bounds.height - 2)
        // White bottom highlight under the button (it sits "in" the brushed bar).
        NSColor(white: 1, alpha: p.isDark ? 0.08 : 0.55).setStroke()
        let under = NSBezierPath(roundedRect: body.offsetBy(dx: 0, dy: 1), xRadius: 4, yRadius: 4)
        under.lineWidth = 1
        under.stroke()

        let shape = NSBezierPath(roundedRect: body, xRadius: 4, yRadius: 4)
        (pressed ? p.texturedButtonPressed : p.texturedButton).drawVertical(in: shape, flipped: true)
        let alpha: CGFloat = 0.55 + 0.45 * activeFraction
        p.texturedButtonBorder.withAlphaComponent(alpha).setStroke()
        shape.lineWidth = 1
        shape.stroke()

        let glyphRect = NSRect(x: bounds.midX - 6.5, y: body.midY - 6.5, width: 13, height: 13)
        NSGraphicsContext.saveGraphicsState()
        p.etchShadow.nsShadow.set()
        let g = glyph.paths(in: glyphRect)
        p.texturedGlyph.withAlphaComponent((0.5 + 0.5 * activeFraction) * (isEnabled ? 1 : 0.4)).set()
        g.stroke.lineCapStyle = .round
        g.stroke.lineJoinStyle = .round
        g.stroke.stroke()
        g.fill?.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
        var inside = true
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            inside = bounds.contains(convert(next.locationInWindow, from: nil))
            pressed = inside
            if next.type == .leftMouseUp { break }
        }
        pressed = false
        if inside { action() }
    }
}

// MARK: - Rounded Lion search field

final class LionSearchField: LionView, NSTextFieldDelegate {
    let textField = FocusAwareTextField()
    var onChange: (String) -> Void = { _ in }
    private var isEditing = false { didSet { ring.setFocused(isEditing) } }
    private let ring = LionFocusRing()
    private let cancelSize: CGFloat = 14
    /// Room around the capsule for the focus ring's contracting animation.
    static let halo = LionMotion.focusRingOutset

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = LionFont.regular(12)
        textField.usesSingleLineMode = true
        textField.lineBreakMode = .byTruncatingTail
        textField.cell?.isScrollable = true
        textField.delegate = self
        textField.onFocus = { [weak self] in self?.isEditing = true }
        ring.onChange = { [weak self] in self?.needsDisplay = true }
        addSubview(textField)
        appearanceDidChange()
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// 3pt margin around the capsule for the focus glow, plus the animation's halo.
    private var capsule: NSRect { bounds.insetBy(dx: 3 + Self.halo, dy: 3 + Self.halo) }

    override var intrinsicContentSize: NSSize { NSSize(width: 200 + 2 * Self.halo, height: 28 + 2 * Self.halo) }

    /// The halo is only for drawing; clicks there belong to whatever is underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard capsule.insetBy(dx: -3, dy: -3).contains(local) else { return nil }
        return super.hitTest(point)
    }

    override func appearanceDidChange() {
        let p = palette
        textField.textColor = p.fieldText
        textField.placeholderAttributedString = NSAttributedString(string: "Search", attributes: [
            .font: LionFont.regular(12), .foregroundColor: p.fieldPlaceholder,
        ])
    }

    override func layout() {
        super.layout()
        let c = capsule
        let rightInset: CGFloat = textField.stringValue.isEmpty ? 8 : cancelSize + 8
        textField.frame = NSRect(x: c.minX + 22, y: c.midY - 8, width: c.width - 22 - rightInset, height: 16)
    }

    private var cancelRect: NSRect {
        let c = capsule
        return NSRect(x: c.maxX - cancelSize - 4, y: c.midY - cancelSize / 2, width: cancelSize, height: cancelSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = palette
        let c = capsule
        let radius = c.height / 2

        // Outer white highlight below the field (sunken into the brushed bar).
        NSColor(white: 1, alpha: p.isDark ? 0.08 : 0.6).setFill()
        NSBezierPath(roundedRect: c.offsetBy(dx: 0, dy: 1), xRadius: radius, yRadius: radius).fill()

        if ring.alpha > 0 {
            let o = 1.5 + ring.outset
            p.focusRing.withAlphaComponent(0.85 * ring.alpha).setStroke()
            let path = NSBezierPath(roundedRect: c.insetBy(dx: -o, dy: -o), xRadius: radius + o, yRadius: radius + o)
            path.lineWidth = 3
            path.stroke()
        }

        let shape = NSBezierPath(roundedRect: c, xRadius: radius, yRadius: radius)
        p.fieldBackground.setFill()
        shape.fill()

        // Inner top shadow.
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        LionGradient(NSColor(white: 0, alpha: p.isDark ? 0.5 : 0.2), NSColor(white: 0, alpha: 0))
            .drawVertical(in: NSRect(x: c.minX, y: c.minY, width: c.width, height: 4), flipped: true)
        NSGraphicsContext.restoreGraphicsState()

        // Border, darker along the top edge.
        let border = NSBezierPath(roundedRect: c.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
        border.lineWidth = 1
        p.fieldBorder.setStroke()
        border.stroke()
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: c.minX, y: c.minY, width: c.width, height: c.height / 2).clip()
        p.fieldTopEdge.setStroke()
        border.stroke()
        NSGraphicsContext.restoreGraphicsState()

        // Magnifier glyph.
        let glyph = NSBezierPath()
        glyph.appendOval(in: NSRect(x: c.minX + 8, y: c.midY - 5, width: 8, height: 8))
        glyph.move(to: NSPoint(x: c.minX + 14.6, y: c.midY + 1.6))
        glyph.line(to: NSPoint(x: c.minX + 18, y: c.midY + 5))
        glyph.lineWidth = 1.6
        glyph.lineCapStyle = .round
        (p.isDark ? NSColor(hex: 0x9aa0a8) : NSColor(hex: 0x6b6b6b)).setStroke()
        glyph.stroke()

        if !textField.stringValue.isEmpty {
            let r = cancelRect
            (p.isDark ? NSColor(hex: 0x7c828a) : NSColor(hex: 0xa9a9a9)).setFill()
            NSBezierPath(ovalIn: r).fill()
            let x = NSBezierPath()
            let i: CGFloat = 4.2
            x.move(to: NSPoint(x: r.minX + i, y: r.minY + i))
            x.line(to: NSPoint(x: r.maxX - i, y: r.maxY - i))
            x.move(to: NSPoint(x: r.maxX - i, y: r.minY + i))
            x.line(to: NSPoint(x: r.minX + i, y: r.maxY - i))
            x.lineWidth = 1.5
            (p.isDark ? p.fieldBackground : .white).setStroke()
            x.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if !textField.stringValue.isEmpty && cancelRect.insetBy(dx: -3, dy: -3).contains(pt) {
            setText("")
            return
        }
        window?.makeFirstResponder(textField)
    }


    func setText(_ text: String) {
        textField.stringValue = text
        textChanged()
    }

    private func textChanged() {
        needsLayout = true
        needsDisplay = true
        onChange(textField.stringValue)
    }

    func controlTextDidChange(_ obj: Notification) { textChanged() }

    func controlTextDidBeginEditing(_ obj: Notification) { isEditing = true }

    func controlTextDidEndEditing(_ obj: Notification) { isEditing = false }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            setText("")
            return true
        }
        return false
    }
}

/// Text field that reports when it gains focus and styles its field editor the Lion way.
final class FocusAwareTextField: NSTextField {
    var onFocus: () -> Void = {}

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            let p = LionTheme.palette(for: effectiveAppearance)
            if let editor = currentEditor() as? NSTextView {
                editor.insertionPointColor = p.fieldText
                editor.selectedTextAttributes = [.backgroundColor: p.textSelection]
            }
            onFocus()
        }
        return ok
    }
}
