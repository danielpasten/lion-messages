import AppKit
import SwiftUI

// Every color, gradient and font of the Lion look lives here.
// Light = Aqua (Mac OS X Lion, 2011). Dark = graphite HUD (Aperture / Final Cut Pro X).

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                  green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255,
                  alpha: alpha)
    }
}

/// A two-stop (or multi-stop) vertical gradient, top color first.
struct LionGradient {
    var stops: [(NSColor, CGFloat)]

    init(_ top: NSColor, _ bottom: NSColor) { stops = [(top, 0), (bottom, 1)] }
    init(stops: [(NSColor, CGFloat)]) { self.stops = stops }

    var nsGradient: NSGradient {
        NSGradient(colors: stops.map(\.0), atLocations: stops.map(\.1), colorSpace: .sRGB)!
    }

    /// Draws top-to-bottom in `rect` (works in flipped and unflipped views).
    func drawVertical(in rect: NSRect, flipped: Bool) {
        nsGradient.draw(in: rect, angle: flipped ? 90 : -90)
    }

    func drawVertical(in path: NSBezierPath, flipped: Bool) {
        nsGradient.draw(in: path, angle: flipped ? 90 : -90)
    }

    var swiftUI: LinearGradient {
        LinearGradient(stops: stops.map { Gradient.Stop(color: Color(nsColor: $0.0), location: $0.1) },
                       startPoint: .top, endPoint: .bottom)
    }
}

/// A text shadow: Lion etched its text with a 1px white (light) or dark (dark) offset shadow.
struct LionTextShadow {
    var color: NSColor
    /// Positive = shadow drawn *below* the text (screen space).
    var dy: CGFloat

    var nsShadow: NSShadow {
        let s = NSShadow()
        s.shadowColor = color
        s.shadowBlurRadius = 0
        // NSShadow offsets are in unflipped base space: negative y = below.
        s.shadowOffset = NSSize(width: 0, height: -dy)
        return s
    }
}

struct LionPalette {
    let isDark: Bool

    // Window top bar
    let toolbarActive: LionGradient
    let toolbarInactive: LionGradient
    let toolbarTopHighlight: NSColor
    let toolbarBottomLine: NSColor
    let titleText: NSColor
    let titleTextInactive: NSColor
    let etchShadow: LionTextShadow

    // Textured toolbar buttons
    let texturedButton: LionGradient
    let texturedButtonPressed: LionGradient
    let texturedButtonBorder: NSColor
    let texturedGlyph: NSColor

    // Search field / sunken fields
    let fieldBackground: NSColor
    let fieldBorder: NSColor
    let fieldTopEdge: NSColor
    let fieldText: NSColor
    let fieldPlaceholder: NSColor
    let focusRing: NSColor
    let textSelection: NSColor

    // Sidebar
    let sidebarBackground: NSColor
    let sidebarDivider: NSColor
    let sidebarHeader: NSColor
    let sidebarName: NSColor
    let sidebarDate: NSColor
    let sidebarPreview: NSColor
    let sidebarSeparator: NSColor
    let sidebarShadow: LionTextShadow
    let selection: LionGradient
    let selectionTopLine: NSColor
    let selectionBottomLine: NSColor
    let selectionInactive: LionGradient
    let selectionInactiveTopLine: NSColor
    let selectionInactiveBottomLine: NSColor
    let selectedText: NSColor
    let selectedTextShadow: LionTextShadow

    // Transcript
    let transcriptBackground: NSColor
    let timestamp: NSColor
    let timestampShadow: LionTextShadow?
    let outgoingBubble: LionGradient
    let outgoingBorder: NSColor
    let outgoingText: NSColor
    let incomingBubble: LionGradient
    let incomingBorder: NSColor
    let incomingText: NSColor
    let attachmentText: NSColor
    let bubbleGloss: NSColor
    let bubbleShadow: NSColor

    // Composer
    let composerTopLine: NSColor
    let composerBar: LionGradient

    // Buttons (Aqua)
    let sendGel: LionGradient
    let sendGelPressed: LionGradient
    let sendBorder: NSColor
    let sendText: NSColor
    let sendTextShadow: LionTextShadow
    let grayGel: LionGradient
    let grayGelPressed: LionGradient
    let grayBorder: NSColor
    let grayText: NSColor
    let disabledText: NSColor

    // Panels (permission screen, sheets)
    let panelFill: LionGradient
    let panelBorder: NSColor
    let panelHeadline: NSColor
    let panelBody: NSColor
    let linenBase: NSColor
    let emptyStateText: NSColor

    // Scrollers
    let scrollerKnob: NSColor

    static let light = LionPalette(
        isDark: false,
        toolbarActive: LionGradient(NSColor(hex: 0xe8e8e8), NSColor(hex: 0xc6c6c6)),
        toolbarInactive: LionGradient(NSColor(hex: 0xf4f4f4), NSColor(hex: 0xdedede)),
        toolbarTopHighlight: .white,
        toolbarBottomLine: NSColor(hex: 0x9a9a9a),
        titleText: NSColor(hex: 0x3c3c3c),
        titleTextInactive: NSColor(hex: 0x9a9a9a),
        etchShadow: LionTextShadow(color: NSColor(white: 1, alpha: 0.75), dy: 1),
        texturedButton: LionGradient(stops: [(NSColor(hex: 0xfdfdfd), 0), (NSColor(hex: 0xe9e9e9), 0.5),
                                             (NSColor(hex: 0xdcdcdc), 0.51), (NSColor(hex: 0xd0d0d0), 1)]),
        texturedButtonPressed: LionGradient(NSColor(hex: 0x9e9e9e), NSColor(hex: 0xbdbdbd)),
        texturedButtonBorder: NSColor(hex: 0x6f6f6f),
        texturedGlyph: NSColor(hex: 0x484848),
        fieldBackground: .white,
        fieldBorder: NSColor(hex: 0xa8a8a8),
        fieldTopEdge: NSColor(hex: 0x868686),
        fieldText: NSColor(hex: 0x1a1a1a),
        fieldPlaceholder: NSColor(hex: 0xa0a0a0),
        focusRing: NSColor(hex: 0x7aacde),
        textSelection: NSColor(hex: 0xb5d5ff),
        sidebarBackground: NSColor(hex: 0xdee4ea),
        sidebarDivider: NSColor(hex: 0xa5a5a5),
        sidebarHeader: NSColor(hex: 0x707e8c),
        sidebarName: NSColor(hex: 0x1c1c1c),
        sidebarDate: NSColor(hex: 0x4f6f99),
        sidebarPreview: NSColor(hex: 0x6a6f75),
        sidebarSeparator: NSColor(hex: 0xc7ced6),
        sidebarShadow: LionTextShadow(color: NSColor(white: 1, alpha: 0.7), dy: 1),
        selection: LionGradient(NSColor(hex: 0x6aa2e2), NSColor(hex: 0x3a78cc)),
        selectionTopLine: NSColor(hex: 0x5a93d6),
        selectionBottomLine: NSColor(hex: 0x2f66b3),
        selectionInactive: LionGradient(NSColor(hex: 0xb4bfd2), NSColor(hex: 0x8c9bb5)),
        selectionInactiveTopLine: NSColor(hex: 0xa6b2c7),
        selectionInactiveBottomLine: NSColor(hex: 0x7d8ca6),
        selectedText: .white,
        selectedTextShadow: LionTextShadow(color: NSColor(white: 0, alpha: 0.35), dy: 1),
        // Messages for Mac's blue-gray transcript (sampled from a 2012 screenshot).
        transcriptBackground: NSColor(hex: 0xe5e9ee),
        timestamp: NSColor(hex: 0x8a8a8a),
        timestampShadow: nil,
        outgoingBubble: LionGradient(NSColor(hex: 0xbfdcf5), NSColor(hex: 0x9cc4e8)),
        outgoingBorder: NSColor(hex: 0x7fa6cb),
        outgoingText: NSColor(hex: 0x1a1a1a),
        incomingBubble: LionGradient(NSColor(hex: 0xebecee), NSColor(hex: 0xd6d7db)),
        incomingBorder: NSColor(hex: 0xa9abaf),
        incomingText: NSColor(hex: 0x1a1a1a),
        attachmentText: NSColor(hex: 0x7a7a7a),
        bubbleGloss: NSColor(white: 1, alpha: 0.85),
        bubbleShadow: NSColor(white: 0, alpha: 0.16),
        composerTopLine: NSColor(hex: 0xb0b0b0),
        composerBar: LionGradient(NSColor(hex: 0xececec), NSColor(hex: 0xd8d8d8)),
        sendGel: LionGradient(stops: [(NSColor(hex: 0xbfe0fb), 0), (NSColor(hex: 0x6fb0ee), 0.49),
                                      (NSColor(hex: 0x4a97e6), 0.5), (NSColor(hex: 0x8cc7f7), 1)]),
        sendGelPressed: LionGradient(stops: [(NSColor(hex: 0x8ec2f0), 0), (NSColor(hex: 0x3f87d6), 0.49),
                                             (NSColor(hex: 0x2c72c4), 0.5), (NSColor(hex: 0x62a6e8), 1)]),
        sendBorder: NSColor(hex: 0x4a7ab5),
        sendText: NSColor(hex: 0x101418),
        sendTextShadow: LionTextShadow(color: NSColor(white: 1, alpha: 0.45), dy: 1),
        grayGel: LionGradient(stops: [(NSColor(hex: 0xffffff), 0), (NSColor(hex: 0xf1f1f1), 0.49),
                                      (NSColor(hex: 0xe0e0e0), 0.5), (NSColor(hex: 0xf4f4f4), 1)]),
        grayGelPressed: LionGradient(stops: [(NSColor(hex: 0xd6d6d6), 0), (NSColor(hex: 0xc4c4c4), 0.49),
                                             (NSColor(hex: 0xb4b4b4), 0.5), (NSColor(hex: 0xcfcfcf), 1)]),
        grayBorder: NSColor(hex: 0x8e8e8e),
        grayText: NSColor(hex: 0x1a1a1a),
        disabledText: NSColor(hex: 0x9a9a9a),
        panelFill: LionGradient(NSColor(hex: 0xfafafa), NSColor(hex: 0xeaeaea)),
        panelBorder: NSColor(hex: 0xa9a9a9),
        panelHeadline: NSColor(hex: 0x2a2a2a),
        panelBody: NSColor(hex: 0x4a4a4a),
        linenBase: NSColor(hex: 0xd9dadc),
        emptyStateText: NSColor(hex: 0x9c9c9c),
        scrollerKnob: NSColor(white: 0, alpha: 0.5)
    )

    static let dark = LionPalette(
        isDark: true,
        toolbarActive: LionGradient(NSColor(hex: 0x4a4a4a), NSColor(hex: 0x313131)),
        toolbarInactive: LionGradient(NSColor(hex: 0x3d3d3d), NSColor(hex: 0x2d2d2d)),
        toolbarTopHighlight: NSColor(white: 1, alpha: 0.15),
        toolbarBottomLine: NSColor(hex: 0x1a1a1a),
        titleText: NSColor(hex: 0xe4e4e4),
        titleTextInactive: NSColor(hex: 0x8a8a8a),
        etchShadow: LionTextShadow(color: NSColor(white: 0, alpha: 0.7), dy: -1),
        texturedButton: LionGradient(stops: [(NSColor(hex: 0x6a6a6a), 0), (NSColor(hex: 0x555555), 0.5),
                                             (NSColor(hex: 0x4a4a4a), 0.51), (NSColor(hex: 0x404040), 1)]),
        texturedButtonPressed: LionGradient(NSColor(hex: 0x2a2a2a), NSColor(hex: 0x3a3a3a)),
        texturedButtonBorder: NSColor(hex: 0x1c1c1c),
        texturedGlyph: NSColor(hex: 0xdedede),
        fieldBackground: NSColor(hex: 0x1a1c1f),
        fieldBorder: NSColor(hex: 0x0f1012),
        fieldTopEdge: NSColor(hex: 0x000000),
        fieldText: NSColor(hex: 0xe8eaed),
        fieldPlaceholder: NSColor(hex: 0x6c7178),
        focusRing: NSColor(hex: 0x5f95d0),
        textSelection: NSColor(hex: 0x3f638b),
        sidebarBackground: NSColor(hex: 0x2b2f35),
        sidebarDivider: NSColor(hex: 0x14161a),
        sidebarHeader: NSColor(hex: 0x8a95a3),
        sidebarName: NSColor(hex: 0xe8eaed),
        sidebarDate: NSColor(hex: 0x8fb0dc),
        sidebarPreview: NSColor(hex: 0x9aa1aa),
        sidebarSeparator: NSColor(hex: 0x23262b),
        sidebarShadow: LionTextShadow(color: NSColor(white: 0, alpha: 0.6), dy: -1),
        selection: LionGradient(NSColor(hex: 0x3f72b8), NSColor(hex: 0x1f4c8a)),
        selectionTopLine: NSColor(hex: 0x5284c6),
        selectionBottomLine: NSColor(hex: 0x163a6c),
        selectionInactive: LionGradient(NSColor(hex: 0x56606f), NSColor(hex: 0x3e4652)),
        selectionInactiveTopLine: NSColor(hex: 0x626c7b),
        selectionInactiveBottomLine: NSColor(hex: 0x2f353e),
        selectedText: .white,
        selectedTextShadow: LionTextShadow(color: NSColor(white: 0, alpha: 0.45), dy: -1),
        transcriptBackground: NSColor(hex: 0x1f2226),
        timestamp: NSColor(hex: 0x8c9198),
        timestampShadow: nil,
        outgoingBubble: LionGradient(NSColor(hex: 0x4677b3), NSColor(hex: 0x2b5487)),
        outgoingBorder: NSColor(hex: 0x1f3f68),
        outgoingText: .white,
        incomingBubble: LionGradient(NSColor(hex: 0x5a5e64), NSColor(hex: 0x3e4247)),
        incomingBorder: NSColor(hex: 0x2a2c30),
        incomingText: NSColor(hex: 0xeceef0),
        attachmentText: NSColor(hex: 0xb4b9c0),
        bubbleGloss: NSColor(white: 1, alpha: 0.22),
        bubbleShadow: NSColor(white: 0, alpha: 0.45),
        composerTopLine: NSColor(hex: 0x111214),
        composerBar: LionGradient(NSColor(hex: 0x3a3d42), NSColor(hex: 0x2a2c30)),
        sendGel: LionGradient(stops: [(NSColor(hex: 0x7aa6dc), 0), (NSColor(hex: 0x3f74b8), 0.49),
                                      (NSColor(hex: 0x2b5c9c), 0.5), (NSColor(hex: 0x4f86c6), 1)]),
        sendGelPressed: LionGradient(stops: [(NSColor(hex: 0x5b88c0), 0), (NSColor(hex: 0x2f5f9c), 0.49),
                                             (NSColor(hex: 0x204b82), 0.5), (NSColor(hex: 0x3a6ca8), 1)]),
        sendBorder: NSColor(hex: 0x14315a),
        sendText: .white,
        sendTextShadow: LionTextShadow(color: NSColor(white: 0, alpha: 0.5), dy: -1),
        grayGel: LionGradient(stops: [(NSColor(hex: 0x6c7076), 0), (NSColor(hex: 0x54585e), 0.49),
                                      (NSColor(hex: 0x484c52), 0.5), (NSColor(hex: 0x5a5e64), 1)]),
        grayGelPressed: LionGradient(stops: [(NSColor(hex: 0x4c5056), 0), (NSColor(hex: 0x3c4046), 0.49),
                                             (NSColor(hex: 0x32363b), 0.5), (NSColor(hex: 0x44484e), 1)]),
        grayBorder: NSColor(hex: 0x16181b),
        grayText: NSColor(hex: 0xeceef0),
        disabledText: NSColor(hex: 0x868a90),
        panelFill: LionGradient(NSColor(hex: 0x3a3e44), NSColor(hex: 0x2e3136)),
        panelBorder: NSColor(hex: 0x121316),
        panelHeadline: NSColor(hex: 0xf0f1f3),
        panelBody: NSColor(hex: 0xc3c8ce),
        linenBase: NSColor(hex: 0x2c2f33),
        emptyStateText: NSColor(hex: 0x6f747b),
        scrollerKnob: NSColor(white: 1, alpha: 0.5)
    )
}

// Rich transcript content: inline media, link cards, file bubbles, buddy pictures.
extension LionPalette {
    /// 1px frame around inline pictures and video thumbnails.
    var mediaBorder: NSColor { isDark ? NSColor(hex: 0x2a2c30) : NSColor(hex: 0xb4b4b4) }
    /// Frame fill while a picture is still decoding.
    var mediaPlaceholder: NSColor { isDark ? NSColor(hex: 0x383b40) : NSColor(hex: 0xe8e8e8) }
    var mediaShadow: NSColor { bubbleShadow }
    /// Links inside bubble text.
    var link: NSColor { isDark ? NSColor(hex: 0x8db7f2) : NSColor(hex: 0x1c4fc0) }
    /// Links inside outgoing bubbles (white-ish on the dark blue gel; regular blue on the light one).
    var linkOutgoing: NSColor { isDark ? NSColor(hex: 0xf2f6ff) : NSColor(hex: 0x1c4fc0) }
    /// Link card: a 2011 Aqua panel (soft gray gradient; graphite in dark).
    var cardFill: LionGradient {
        isDark ? LionGradient(NSColor(hex: 0x4a4e55), NSColor(hex: 0x363a3f))
               : LionGradient(NSColor(hex: 0xfcfcfc), NSColor(hex: 0xe6e6e6))
    }
    var cardBorder: NSColor { isDark ? NSColor(hex: 0x1c1e21) : NSColor(hex: 0xb4b4b4) }
    var cardHighlight: NSColor { isDark ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 1, alpha: 0.9) }
    var cardImageDivider: NSColor { isDark ? NSColor(hex: 0x1c1e21) : NSColor(hex: 0xc4c4c4) }
    var cardTitle: NSColor { isDark ? NSColor(hex: 0xeceef0) : NSColor(hex: 0x1a1a1a) }
    var cardSummary: NSColor { isDark ? NSColor(hex: 0xb0b5bc) : NSColor(hex: 0x5e5e5e) }
    var cardSite: NSColor { isDark ? NSColor(hex: 0x8f959c) : NSColor(hex: 0x8a8a8a) }
    /// File bubbles: secondary line (size) on incoming / outgoing gel.
    var fileDetailIncoming: NSColor { isDark ? NSColor(hex: 0xaeb3ba) : NSColor(hex: 0x7a7a7a) }
    var fileDetailOutgoing: NSColor { isDark ? NSColor(hex: 0xbcd0ea) : NSColor(hex: 0x5a7593) }
    /// "+3 more" under a capped attachment stack.
    var moreText: NSColor { timestamp }
    /// Buddy pictures: square frame, and the generic silhouette used when there is no picture.
    var buddyBorder: NSColor { isDark ? NSColor(white: 0, alpha: 0.6) : NSColor(white: 0, alpha: 0.35) }
    var buddyShadow: NSColor { isDark ? NSColor(white: 0, alpha: 0.4) : NSColor(white: 0, alpha: 0.18) }
    var buddyPlaceholder: LionGradient {
        isDark ? LionGradient(NSColor(hex: 0x737880), NSColor(hex: 0x4a4e55))
               : LionGradient(NSColor(hex: 0xdedede), NSColor(hex: 0xa9a9a9))
    }
    var buddyGlyph: NSColor { isDark ? NSColor(hex: 0xb9bdc3) : NSColor(hex: 0xf7f7f7) }
    var buddyGlyphBack: NSColor { isDark ? NSColor(hex: 0x9a9fa6) : NSColor(white: 1, alpha: 0.62) }
    /// Ring between the front and back figures of the group glyph.
    var buddyGlyphOutline: NSColor { isDark ? NSColor(hex: 0x5c6168) : NSColor(hex: 0xb9b9b9) }
}

enum LionTheme {
    static func palette(dark: Bool) -> LionPalette { dark ? .dark : .light }

    static func palette(for appearance: NSAppearance) -> LionPalette {
        palette(dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }

    static func palette(for scheme: ColorScheme) -> LionPalette { palette(dark: scheme == .dark) }
}

enum LionFont {
    static func regular(_ size: CGFloat) -> NSFont {
        NSFont(name: "LucidaGrande", size: size) ?? .systemFont(ofSize: size)
    }

    static func bold(_ size: CGFloat) -> NSFont {
        NSFont(name: "LucidaGrande-Bold", size: size) ?? .boldSystemFont(ofSize: size)
    }

    static func mono(_ size: CGFloat) -> NSFont {
        NSFont(name: "Menlo-Regular", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Lucida Grande has no italic; Lion synthesized an oblique the same way.
    static func oblique(_ size: CGFloat) -> NSFont {
        let base = regular(size)
        let skew = AffineTransform(m11: size, m12: 0, m21: 0.2 * size, m22: size, tX: 0, tY: 0)
        let descriptor = base.fontDescriptor.withMatrix(skew)
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    static func swiftUI(_ size: CGFloat, bold: Bool = false) -> Font {
        .custom(bold ? "LucidaGrande-Bold" : "LucidaGrande", fixedSize: size)
    }

    static func swiftUIMono(_ size: CGFloat) -> Font { .custom("Menlo-Regular", fixedSize: size) }
}

extension LionTextShadow {
    var swiftUIColor: Color { Color(nsColor: color) }
}

extension View {
    /// Lion's 1px etched text shadow.
    func lionEtched(_ shadow: LionTextShadow) -> some View {
        self.shadow(color: shadow.swiftUIColor, radius: 0, x: 0, y: shadow.dy)
    }
}
