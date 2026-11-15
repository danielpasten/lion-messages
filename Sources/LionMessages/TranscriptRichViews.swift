import AppKit
import MessagesModel

// The views inside a transcript row: gel text bubbles, framed pictures, file bubbles, link cards
// and iChat buddy pictures. All draw themselves (so `cacheDisplay` snapshots see exactly what's
// on screen) and none of them changes size after it has been measured.

enum TranscriptScale {
    /// Bitmaps are decoded for the sharpest attached screen, so moving the window never re-decodes.
    @MainActor static var current: CGFloat { NSScreen.screens.map(\.backingScaleFactor).max() ?? 2 }
}

/// Draws a CGImage into `rect` of a flipped view, upright.
private func drawImage(_ image: CGImage, in rect: NSRect, ctx: CGContext) {
    ctx.saveGState()
    ctx.interpolationQuality = .high
    ctx.translateBy(x: rect.minX, y: rect.maxY)
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
    ctx.restoreGState()
}

/// The rect that covers `target` with an image of `size`, centered (aspect-fill).
private func fillRect(for size: CGSize, in target: NSRect) -> NSRect {
    guard size.width > 0, size.height > 0 else { return target }
    let scale = max(target.width / size.width, target.height / size.height)
    let w = size.width * scale, h = size.height * scale
    return NSRect(x: target.midX - w / 2, y: target.midY - h / 2, width: w, height: h)
}

/// One picture slot: asks the loader, ignores results that arrive after the view was reused.
@MainActor
final class MediaSlot {
    private(set) var image: CGImage?
    private var request: MediaLoader.Request?
    private var token: MediaLoader.Token?
    var onChange: () -> Void = {}

    func set(_ new: MediaLoader.Request?, async: Bool) {
        guard new != request else { return }
        if let token { MediaLoader.shared.cancel(token) }
        token = nil
        request = new
        image = new.flatMap { MediaLoader.shared.cached($0) }
        guard let new, image == nil, async else { return }
        token = MediaLoader.shared.load(new) { [weak self] image in
            guard let self, self.request == new else { return }
            self.token = nil
            self.image = image
            self.onChange()
        }
    }
}

/// Opens something on click, with the pointing hand over it.
class ClickableView: NSView {
    var onClick: (() -> Void)?
    private var pressed = false
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The clickable area (the body, not the shadow margin).
    var hitRect: NSRect { bounds.insetBy(dx: 1, dy: 1) }

    override func resetCursorRects() {
        if onClick != nil { addCursorRect(hitRect, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {
        pressed = hitRect.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        guard pressed, hitRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }
}

// MARK: - Gel text bubble

/// The glossy iChat gel bubble with a selectable text view inside.
final class BubbleView: NSView {
    let textView = NSTextView()
    private var isFromMe = false
    private var text: BubbleText?

    override var isFlipped: Bool { true }

    static func textFrame(textSize: NSSize) -> NSRect {
        NSRect(x: 1 + BubbleMetrics.padX, y: 1 + BubbleMetrics.padY, width: textSize.width + 1, height: textSize.height)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.focusRingType = .none
        textView.isAutomaticLinkDetectionEnabled = false
        addSubview(textView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(text t: BubbleText, isFromMe: Bool, containerWidth: CGFloat) {
        text = t
        self.isFromMe = isFromMe
        textView.textContainer?.containerSize = NSSize(width: containerWidth, height: .greatestFiniteMagnitude)
        applyText()
        needsDisplay = true
    }

    private func applyText() {
        guard let t = text else { return }
        let p = LionTheme.palette(for: effectiveAppearance)
        textView.textStorage?.setAttributedString(t.attributed(isFromMe: isFromMe, palette: p))
        textView.selectedTextAttributes = [.backgroundColor: p.textSelection]
        textView.insertionPointColor = isFromMe ? p.outgoingText : p.incomingText
        if !t.links.isEmpty {
            textView.linkTextAttributes = [
                .foregroundColor: isFromMe ? p.linkOutgoing : p.link,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .cursor: NSCursor.pointingHand,
            ]
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyText()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let body = NSRect(x: 1, y: 1, width: bounds.width - 2, height: bounds.height - 1 - BubbleMetrics.shadowRoom)
        Self.drawGel(in: body, isFromMe: isFromMe, palette: LionTheme.palette(for: effectiveAppearance), ctx: ctx)
    }

    /// The gel: drop shadow, gradient body, gloss, inner highlight and border.
    static func drawGel(in body: NSRect, isFromMe: Bool, palette p: LionPalette, ctx: CGContext) {
        let radius = min(16, body.height / 2, body.width / 2)
        let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let fill = isFromMe ? p.outgoingBubble : p.incomingBubble

        // Drop shadow (0/1px, low alpha).
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 1.5, color: p.bubbleShadow.cgColor)
        ctx.addPath(path)
        ctx.setFillColor(fill.stops.last!.0.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        // Gel body.
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        fill.drawVertical(in: body, flipped: true)

        // Gloss: a soft white sheen over the top half.
        let gloss = NSRect(x: body.minX, y: body.minY, width: body.width, height: body.height * 0.5)
        let g = p.bubbleGloss.alphaComponent
        LionGradient(p.bubbleGloss.withAlphaComponent(g * 0.75),
                     p.bubbleGloss.withAlphaComponent(g * 0.2)).drawVertical(in: gloss, flipped: true)
        ctx.restoreGState()

        // Inner 1px highlight fading out down the top half.
        let inner = body.insetBy(dx: 1, dy: 1)
        let innerRadius = max(0, radius - 1)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: inner, cornerWidth: innerRadius, cornerHeight: innerRadius, transform: nil))
        ctx.setLineWidth(1)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        LionGradient(stops: [(p.bubbleGloss, 0), (p.bubbleGloss.withAlphaComponent(0), 0.55),
                             (p.bubbleGloss.withAlphaComponent(0), 1)])
            .drawVertical(in: inner, flipped: true)
        ctx.restoreGState()

        // Border.
        let borderRect = body.insetBy(dx: 0.5, dy: 0.5)
        ctx.addPath(CGPath(roundedRect: borderRect, cornerWidth: radius - 0.5, cornerHeight: radius - 0.5, transform: nil))
        ctx.setStrokeColor((isFromMe ? p.outgoingBorder : p.incomingBorder).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
    }
}

// MARK: - Pictures and video thumbnails

/// A framed inline picture (or a frameless sticker, or a video thumbnail with a play glyph).
final class MediaView: ClickableView {
    static let radius: CGFloat = 8
    private let slot = MediaSlot()
    private var pixelSize = CGSize.zero
    private var isSticker = false
    private var isVideo = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        slot.onChange = { [weak self] in
            self?.needsDisplay = true
            self?.onImageLoaded?()
        }
    }

    /// Set by the row: a picture finished loading.
    var onImageLoaded: (() -> Void)?

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(attachment a: MessageAttachment, pixelSize: CGSize, isVideo: Bool, displaySize: NSSize, async: Bool) {
        self.pixelSize = pixelSize
        isSticker = a.isSticker && !isVideo
        self.isVideo = isVideo
        guard let url = a.fileURL else { slot.set(nil, async: false); return }
        let maxPixel = MediaLoader.maxPixel(source: isVideo ? .zero : pixelSize, display: displaySize,
                                            scale: TranscriptScale.current)
        slot.set(.init(id: "a\(a.id)", url: url, kind: isVideo ? .videoThumbnail : .image, maxPixel: maxPixel),
                 async: async)
        onClick = {
            if isVideo { NSWorkspace.shared.open(url) } else { QuickLookCoordinator.shared.preview(url) }
        }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let p = LionTheme.palette(for: effectiveAppearance)
        let body = NSRect(x: 1, y: 1, width: bounds.width - 2, height: bounds.height - 1 - BubbleMetrics.shadowRoom)
        if isSticker {
            if let image = slot.image { drawImage(image, in: body, ctx: ctx) }
            return
        }
        let path = CGPath(roundedRect: body, cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 1.5, color: p.mediaShadow.cgColor)
        ctx.addPath(path)
        ctx.setFillColor(p.mediaPlaceholder.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        if let image = slot.image {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            drawImage(image, in: fillRect(for: CGSize(width: image.width, height: image.height), in: body), ctx: ctx)
            ctx.restoreGState()
        }
        if isVideo { Self.drawPlayGlyph(center: NSPoint(x: body.midX, y: body.midY), ctx: ctx) }

        ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 0.5, dy: 0.5), cornerWidth: Self.radius - 0.5,
                           cornerHeight: Self.radius - 0.5, transform: nil))
        ctx.setStrokeColor(p.mediaBorder.cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
    }

    /// QuickTime-era play button: a dark translucent disc with a white rim and triangle.
    private static func drawPlayGlyph(center c: NSPoint, ctx: CGContext) {
        let r: CGFloat = 15
        let disc = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: NSColor(white: 0, alpha: 0.4).cgColor)
        ctx.setFillColor(NSColor(white: 0, alpha: 0.45).cgColor)
        ctx.fillEllipse(in: disc)
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.9).cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: disc.insetBy(dx: 0.75, dy: 0.75))
        ctx.beginPath()
        ctx.move(to: CGPoint(x: c.x - 4.5, y: c.y - 7))
        ctx.addLine(to: CGPoint(x: c.x + 7.5, y: c.y))
        ctx.addLine(to: CGPoint(x: c.x - 4.5, y: c.y + 7))
        ctx.closePath()
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
    }
}

// MARK: - File bubble

/// Lion-style file transfer bubble: the Finder icon, the file name and its size.
final class FileBubbleView: ClickableView {
    private static let icons = NSCache<NSString, NSImage>()
    private var attachment: MessageAttachment?
    private var url: URL?
    private var isFromMe = false

    func configure(attachment a: MessageAttachment, url: URL, isFromMe: Bool) {
        attachment = a
        self.url = url
        self.isFromMe = isFromMe
        onClick = { NSWorkspace.shared.open(url) }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    private static func icon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let icon = icons.object(forKey: key) { return icon }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons.setObject(icon, forKey: key)
        return icon
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let a = attachment, let url else { return }
        let p = LionTheme.palette(for: effectiveAppearance)
        let body = NSRect(x: 1, y: 1, width: bounds.width - 2, height: bounds.height - 1 - BubbleMetrics.shadowRoom)
        BubbleView.drawGel(in: body, isFromMe: isFromMe, palette: p, ctx: ctx)

        let m = FileBubbleMetrics.self
        let iconRect = NSRect(x: body.minX + m.leftPad, y: body.minY + (body.height - m.iconSize) / 2,
                              width: m.iconSize, height: m.iconSize)
        Self.icon(for: url).draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1,
                                 respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])

        let textX = body.minX + m.textX
        let textW = body.maxX - m.rightPad - textX
        let middle = NSMutableParagraphStyle()
        middle.lineBreakMode = .byTruncatingMiddle
        NSAttributedString(string: m.name(a, url: url), attributes: [
            .font: m.nameFont, .foregroundColor: isFromMe ? p.outgoingText : p.incomingText, .paragraphStyle: middle,
        ]).draw(with: NSRect(x: textX, y: body.minY + 6, width: textW, height: 16), options: [.usesLineFragmentOrigin])
        let tail = NSMutableParagraphStyle()
        tail.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: m.detail(a, url: url), attributes: [
            .font: m.detailFont, .foregroundColor: isFromMe ? p.fileDetailOutgoing : p.fileDetailIncoming,
            .paragraphStyle: tail,
        ]).draw(with: NSRect(x: textX, y: body.minY + 23, width: textW, height: 14), options: [.usesLineFragmentOrigin])
    }
}

// MARK: - "+N more"

final class MoreView: NSView {
    static let font = LionFont.regular(11)
    static func label(_ n: Int) -> String { "+\(n) more" }
    var count = 0 { didSet { needsDisplay = true } }
    var alignRight = false
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let p = LionTheme.palette(for: effectiveAppearance)
        let s = NSAttributedString(string: Self.label(count), attributes: [.font: Self.font, .foregroundColor: p.moreText])
        let w = s.size().width
        s.draw(at: NSPoint(x: alignRight ? bounds.width - w - 1 : 1, y: 0))
    }
}

// MARK: - Link card

/// A rich link as a small Aqua panel: picture, bold title, gray summary, site line.
final class LinkCardView: ClickableView {
    static let radius: CGFloat = 8
    private let imageSlot = MediaSlot()
    private let iconSlot = MediaSlot()
    private var layout: CardLayout?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageSlot.onChange = { [weak self] in
            self?.needsDisplay = true
            self?.onImageLoaded?()
        }
        iconSlot.onChange = { [weak self] in
            self?.needsDisplay = true
            self?.onImageLoaded?()
        }
    }

    /// Set by the row: a picture finished loading.
    var onImageLoaded: (() -> Void)?

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(preview: LinkPreview, messageID: Int64, imagePixelSize: CGSize?, layout: CardLayout, async: Bool) {
        self.layout = layout
        let scale = TranscriptScale.current
        if let url = preview.imageFileURL, let size = imagePixelSize, layout.imageHeight > 0 {
            let display = CGSize(width: layout.width, height: layout.imageHeight)
            imageSlot.set(.init(id: "p\(messageID)", url: url, kind: .image,
                                maxPixel: MediaLoader.maxPixel(source: size, display: display, scale: scale)), async: async)
        } else {
            imageSlot.set(nil, async: false)
        }
        if let url = preview.iconFileURL {
            let side = CardLayout.iconSize
            let size = MediaGeometry.pixelSize(of: url) ?? CGSize(width: side, height: side)
            iconSlot.set(.init(id: "i\(messageID)", url: url, kind: .image,
                               maxPixel: MediaLoader.maxPixel(source: size, display: CGSize(width: side, height: side),
                                                              scale: scale)), async: async)
        } else {
            iconSlot.set(nil, async: false)
        }
        let target = preview.url
        onClick = { NSWorkspace.shared.open(target) }
        setAccessibilityElement(true)
        setAccessibilityRole(.link)
        setAccessibilityLabel([layout.title, layout.site].compactMap { $0 }.joined(separator: ", "))
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let l = layout else { return }
        let p = LionTheme.palette(for: effectiveAppearance)
        let body = NSRect(x: 1, y: 1, width: bounds.width - 2, height: bounds.height - 1 - BubbleMetrics.shadowRoom)
        let r = Self.radius
        let path = CGPath(roundedRect: body, cornerWidth: r, cornerHeight: r, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 1.5, color: p.mediaShadow.cgColor)
        ctx.addPath(path)
        ctx.setFillColor(p.cardFill.stops.last!.0.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        p.cardFill.drawVertical(in: body, flipped: true)
        if l.imageHeight > 0 {
            let imageRect = NSRect(x: body.minX, y: body.minY, width: body.width, height: l.imageHeight)
            if let image = imageSlot.image {
                ctx.saveGState()
                ctx.clip(to: imageRect)
                drawImage(image, in: fillRect(for: CGSize(width: image.width, height: image.height), in: imageRect), ctx: ctx)
                ctx.restoreGState()
            } else {
                ctx.setFillColor(p.mediaPlaceholder.cgColor)
                ctx.fill(imageRect)
            }
            ctx.setFillColor(p.cardImageDivider.cgColor)
            ctx.fill(CGRect(x: body.minX, y: imageRect.maxY, width: body.width, height: 1))
            // The panel's top highlight under the picture.
            ctx.setFillColor(p.cardHighlight.cgColor)
            ctx.fill(CGRect(x: body.minX, y: imageRect.maxY + 1, width: body.width, height: 1))
        } else {
            ctx.setFillColor(p.cardHighlight.cgColor)
            ctx.fill(CGRect(x: body.minX + r, y: body.minY + 1, width: body.width - 2 * r, height: 1))
        }
        ctx.restoreGState()

        let x = body.minX + CardLayout.padX
        let w = body.width - 2 * CardLayout.padX
        if let title = l.title {
            NSAttributedString(string: title, attributes: CardLayout.titleAttributes(p.cardTitle))
                .draw(with: NSRect(x: x, y: body.minY + l.titleY, width: w, height: l.titleHeight),
                      options: CardLayout.drawOptions)
        }
        if let summary = l.summary {
            NSAttributedString(string: summary, attributes: CardLayout.summaryAttributes(p.cardSummary))
                .draw(with: NSRect(x: x, y: body.minY + l.summaryY, width: w, height: l.summaryHeight),
                      options: CardLayout.drawOptions)
        }
        var siteX = x
        let footerY = body.minY + l.footerY
        if let icon = iconSlot.image {
            let s = CardLayout.iconSize
            let iconRect = NSRect(x: x, y: footerY, width: s, height: s)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: iconRect, cornerWidth: 2, cornerHeight: 2, transform: nil))
            ctx.clip()
            drawImage(icon, in: fillRect(for: CGSize(width: icon.width, height: icon.height), in: iconRect), ctx: ctx)
            ctx.restoreGState()
            siteX += s + 5
        }
        NSAttributedString(string: l.site, attributes: CardLayout.siteAttributes(p.cardSite))
            .draw(with: NSRect(x: siteX, y: footerY + 1.5, width: body.maxX - CardLayout.padX - siteX, height: 14),
                  options: [.usesLineFragmentOrigin])

        let border = body.insetBy(dx: 0.5, dy: 0.5)
        ctx.addPath(CGPath(roundedRect: border, cornerWidth: r - 0.5, cornerHeight: r - 0.5, transform: nil))
        ctx.setStrokeColor(p.cardBorder.cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
    }
}

// MARK: - Buddy pictures

enum BuddyPicture {
    static let radius: CGFloat = 3

    /// iChat's square buddy picture (or the generic silhouette) in `rect` of a flipped view.
    static func draw(_ image: NSImage?, isGroup: Bool = false, in rect: NSRect, palette p: LionPalette, ctx: CGContext) {
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 1.5, color: p.buddyShadow.cgColor)
        ctx.addPath(path)
        ctx.setFillColor(p.buddyPlaceholder.stops.last!.0.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        if let image {
            image.draw(in: fillRect(for: image.size, in: rect), from: .zero, operation: .copy, fraction: 1,
                       respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        } else {
            p.buddyPlaceholder.drawVertical(in: rect, flipped: true)
            let s = rect.width
            if isGroup {
                silhouette(in: NSRect(x: rect.minX - 0.06 * s, y: rect.minY + 0.1 * s, width: 0.86 * s, height: 0.86 * s),
                           color: p.buddyGlyphBack)
                silhouette(in: NSRect(x: rect.minX + 0.28 * s, y: rect.minY + 0.22 * s, width: 0.78 * s, height: 0.78 * s),
                           color: p.buddyGlyph, outline: p.buddyGlyphOutline, outlineWidth: max(1, s / 20))
            } else {
                silhouette(in: rect.insetBy(dx: 0.04 * s, dy: 0.04 * s).offsetBy(dx: 0, dy: 0.04 * s), color: p.buddyGlyph)
            }
        }
        ctx.restoreGState()

        ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius - 0.5,
                           cornerHeight: radius - 0.5, transform: nil))
        ctx.setStrokeColor(p.buddyBorder.cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
    }

    /// The classic default buddy: a head over rounded shoulders, filling `r` to its bottom edge.
    private static func silhouette(in r: NSRect, color: NSColor, outline: NSColor? = nil, outlineWidth: CGFloat = 0) {
        let s = r.width
        let head = NSBezierPath(ovalIn: NSRect(x: r.midX - 0.2 * s, y: r.minY + 0.12 * s, width: 0.4 * s, height: 0.44 * s))
        let body = NSBezierPath()
        body.move(to: NSPoint(x: r.minX + 0.06 * s, y: r.maxY + 1))
        body.curve(to: NSPoint(x: r.midX, y: r.minY + 0.6 * s),
                   controlPoint1: NSPoint(x: r.minX + 0.08 * s, y: r.minY + 0.7 * s),
                   controlPoint2: NSPoint(x: r.midX - 0.24 * s, y: r.minY + 0.6 * s))
        body.curve(to: NSPoint(x: r.maxX - 0.06 * s, y: r.maxY + 1),
                   controlPoint1: NSPoint(x: r.midX + 0.24 * s, y: r.minY + 0.6 * s),
                   controlPoint2: NSPoint(x: r.maxX - 0.08 * s, y: r.minY + 0.7 * s))
        body.close()
        if let outline {
            // Separates the front figure from the one behind it.
            outline.setStroke()
            for path in [head, body] {
                path.lineWidth = outlineWidth * 2
                path.stroke()
            }
        }
        color.setFill()
        head.fill()
        body.fill()
    }
}

final class BuddyPictureView: NSView {
    var image: NSImage? { didSet { if image !== oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = BuddyMetrics.size
        BuddyPicture.draw(image, in: NSRect(x: 1, y: 1, width: s, height: s),
                          palette: LionTheme.palette(for: effectiveAppearance), ctx: ctx)
    }
}

// MARK: - The row

/// One message: its parts stacked on the sender's side, plus the buddy picture of a run's last bubble.
final class MessageCell: NSView {
    private var partViews: [NSView] = []
    private var partKinds: [Int] = []
    private let avatarView = BuddyPictureView()
    private var geometry: MessageGeometry?
    /// Off for offscreen copies that only need what's already cached.
    var loadsAsync = true
    /// A picture inside this row finished loading (the arrival stand-in re-renders).
    var onImageLoaded: (() -> Void)?
    /// While a new message animates in, a stand-in draws it and the real views wait hidden.
    var isArriving = false { didSet { if isArriving != oldValue { applyHidden() } } }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(avatarView)
        avatarView.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(message m: Message, geometry g: MessageGeometry, avatar: NSImage?) {
        geometry = g
        let kinds = g.parts.map(\.part.viewKind)
        if kinds != partKinds {
            partViews.forEach { $0.removeFromSuperview() }
            partViews = kinds.map { kind -> NSView in
                switch kind {
                case 0: return BubbleView(frame: .zero)
                case 1: return MediaView(frame: .zero)
                case 2: return FileBubbleView(frame: .zero)
                case 3: return MoreView(frame: .zero)
                default: return LinkCardView(frame: .zero)
                }
            }
            partViews.forEach { addSubview($0, positioned: .below, relativeTo: avatarView) }
            for view in partViews {
                let notify: () -> Void = { [weak self] in self?.onImageLoaded?() }
                (view as? MediaView)?.onImageLoaded = notify
                (view as? LinkCardView)?.onImageLoaded = notify
            }
            partKinds = kinds
        }
        for (i, placed) in g.parts.enumerated() {
            switch (placed.part, partViews[i]) {
            case (.text(let t), let v as BubbleView):
                v.configure(text: t, isFromMe: m.isFromMe, containerWidth: placed.text?.containerWidth ?? placed.size.width)
            case (.media(let a, let pixelSize, let isVideo), let v as MediaView):
                v.configure(attachment: a, pixelSize: pixelSize, isVideo: isVideo, displaySize: placed.size, async: loadsAsync)
            case (.file(let a, let url), let v as FileBubbleView):
                v.configure(attachment: a, url: url, isFromMe: m.isFromMe)
            case (.more(let n), let v as MoreView):
                v.count = n
                v.alignRight = m.isFromMe
            case (.card(let preview, let id, let imageSize), let v as LinkCardView):
                if let layout = placed.card {
                    v.configure(preview: preview, messageID: id, imagePixelSize: imageSize, layout: layout, async: loadsAsync)
                }
            default:
                break
            }
        }
        avatarView.image = avatar
        applyHidden()
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        let text = g.parts.compactMap { part -> String? in
            switch part.part {
            case .text(let t): return t.string
            case .media(_, _, let isVideo): return isVideo ? "Video" : "Picture"
            case .file(let a, let url): return FileBubbleMetrics.name(a, url: url)
            case .more(let n): return MoreView.label(n)
            case .card(let p, _, _): return p.title ?? p.url.host
            }
        }.joined(separator: ", ")
        setAccessibilityLabel(m.isFromMe ? "You: \(text)" : "\(m.senderName ?? "Them"): \(text)")
        needsLayout = true
    }

    func setAvatar(_ image: NSImage?) { avatarView.image = image }

    private func applyHidden() {
        partViews.forEach { $0.isHidden = isArriving }
        avatarView.isHidden = isArriving || geometry?.avatarY == nil
    }

    override func layout() {
        super.layout()
        guard let g = geometry else { return }
        let w = bounds.width
        for (i, view) in partViews.enumerated() where i < g.parts.count {
            view.frame = g.viewFrame(i, cellWidth: w)
            if let bubble = view as? BubbleView, let text = g.parts[i].text {
                bubble.textView.frame = BubbleView.textFrame(textSize: text.size)
            }
        }
        if let a = g.avatarFrame(cellWidth: w) { avatarView.frame = a }
    }

    /// An offscreen row configured exactly like a table cell (the arrival animation pictures it,
    /// and re-pictures it when its pictures finish loading).
    static func stage(message m: Message, geometry g: MessageGeometry, avatar: NSImage?, cellSize: NSSize,
                      appearance: NSAppearance) -> MessageCell {
        let cell = MessageCell(frame: NSRect(origin: .zero, size: cellSize))
        cell.appearance = appearance
        cell.configure(message: m, geometry: g, avatar: avatar)
        cell.layoutSubtreeIfNeeded()
        return cell
    }
}

extension NSView {
    /// A Retina picture of part of the view as it is drawn right now.
    func lionSnapshot(of rect: NSRect, scale: CGFloat) -> NSImage? {
        guard rect.width > 0, rect.height > 0, let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(ceil(rect.width * scale)), pixelsHigh: Int(ceil(rect.height * scale)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = rect.size
        cacheDisplay(in: rect, to: rep)
        let image = NSImage(size: rect.size)
        image.addRepresentation(rep)
        return image
    }
}
