import AppKit
import MessagesModel
import SwiftUI

// SwiftUI pieces of the Lion look: Aqua gel buttons, etched empty-state text, the linen
// background, and the sheet that drops out of the toolbar.

struct AquaButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    var kind: Kind
    var height: CGFloat = 22
    /// Show the pressed look regardless of the mouse (Return-to-send).
    var forcePressed = false
    /// Lion's default buttons gently pulsed. Only for a window's default (blue) button.
    var pulses = false

    func makeBody(configuration: Configuration) -> some View {
        AquaButtonBody(configuration: configuration, kind: kind, height: height,
                       forcePressed: forcePressed, pulses: pulses)
    }
}

private struct AquaButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: AquaButtonStyle.Kind
    let height: CGFloat
    let forcePressed: Bool
    let pulses: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        let p = LionTheme.palette(for: scheme)
        let pressed = configuration.isPressed || forcePressed
        let blue = kind == .primary && isEnabled
        let gel: LionGradient = blue ? p.sendGel : p.grayGel
        let gelPressed: LionGradient = blue ? p.sendGelPressed : p.grayGelPressed
        let border = blue ? p.sendBorder : p.grayBorder
        let textColor: NSColor = !isEnabled ? p.disabledText : (blue ? p.sendText : p.grayText)
        let textShadow = blue ? p.sendTextShadow : p.etchShadow
        let pulsing = pulses && blue && !pressed && activeState == .key
            && !LionMotion.isDisabled && !LionMotion.reduceMotion

        configuration.label
            .font(LionFont.swiftUI(13))
            .foregroundColor(Color(nsColor: textColor))
            .lionEtched(textShadow)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 18)
            .frame(minWidth: 70)
            .frame(height: height)
            .background(
                ZStack {
                    Capsule().fill(gel.swiftUI)
                    // The pressed gel crossfades in and out rather than snapping.
                    Capsule().fill(gelPressed.swiftUI).opacity(pressed ? 1 : 0)
                    if pulsing {
                        AquaPulse(isDark: p.isDark)
                    }
                    // The Aqua "gel" reflection over the top half.
                    GeometryReader { geo in
                        Capsule()
                            .fill(LinearGradient(colors: [Color.white.opacity(p.isDark ? 0.35 : 0.85),
                                                          Color.white.opacity(p.isDark ? 0.05 : 0.25)],
                                                 startPoint: .top, endPoint: .bottom))
                            .frame(width: geo.size.width - 6, height: geo.size.height * 0.48)
                            .offset(x: 3, y: 1.5)
                    }
                    Capsule().strokeBorder(Color(nsColor: border.withAlphaComponent(isEnabled ? 1 : 0.6)), lineWidth: 1)
                }
                .opacity(isEnabled ? 1 : 0.75)
                .shadow(color: .black.opacity(p.isDark ? 0.4 : 0.18), radius: 0.5, x: 0, y: 1)
                .animation(LionMotion.easeOut(LionMotion.buttonPress), value: pressed)
            )
            .contentShape(Capsule())
    }
}

/// The default button's slow "breathing": a soft brightening of the blue gel, ~1 s per cycle.
private struct AquaPulse: View {
    let isDark: Bool

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate / LionMotion.duration(LionMotion.defaultButtonPulsePeriod)
            let amount = 0.5 - 0.5 * cos(2 * .pi * t)
            Capsule().fill(Color.white.opacity((isDark ? 0.14 : 0.24) * amount))
        }
        .allowsHitTesting(false)
    }
}

/// Lion's etched gray placeholder text ("No Conversation Selected").
struct EtchedText: View {
    let text: String
    var size: CGFloat = 18
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = LionTheme.palette(for: scheme)
        Text(text)
            .font(LionFont.swiftUI(size, bold: true))
            .foregroundColor(Color(nsColor: p.emptyStateText))
            .lionEtched(p.isDark ? LionTextShadow(color: NSColor(white: 0, alpha: 0.6), dy: -1)
                                 : LionTextShadow(color: .white, dy: 1))
            .multilineTextAlignment(.center)
            .allowsHitTesting(false)
    }
}

/// Procedural Lion linen, tiled.
enum Linen {
    private static var cache: [Bool: NSImage] = [:]

    static func image(dark: Bool) -> NSImage {
        if let img = cache[dark] { return img }
        let size = 160
        let base = LionTheme.palette(dark: dark).linenBase
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            base.setFill()
            rect.fill()
            var rng = SeededRandom(seed: 0x11071)
            let light = dark ? NSColor.white : NSColor.white
            let shade = NSColor.black
            for i in 0..<size {
                // Horizontal and vertical threads of varying strength.
                let a1 = CGFloat(rng.next() % 100) / 100 * (dark ? 0.06 : 0.12)
                (i % 2 == 0 ? light : shade).withAlphaComponent(a1).setFill()
                NSRect(x: 0, y: CGFloat(i), width: CGFloat(size), height: 1).fill()
                let a2 = CGFloat(rng.next() % 100) / 100 * (dark ? 0.07 : 0.08)
                (i % 3 == 0 ? light : shade).withAlphaComponent(a2).setFill()
                NSRect(x: CGFloat(i), y: 0, width: 1, height: CGFloat(size)).fill()
            }
            // Fine speckle.
            for _ in 0..<1800 {
                let x = CGFloat(rng.next() % UInt64(size)), y = CGFloat(rng.next() % UInt64(size))
                (rng.next() % 2 == 0 ? light : shade).withAlphaComponent(dark ? 0.05 : 0.07).setFill()
                NSRect(x: x, y: y, width: 1, height: 1).fill()
            }
            return true
        }
        cache[dark] = img
        return img
    }
}

struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 33
    }
}

struct LinenBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Image(nsImage: Linen.image(dark: scheme == .dark))
            .resizable(resizingMode: .tile)
            .overlay(
                // Gentle vignette, as Lion's linen surfaces had.
                RadialGradient(colors: [.clear, .black.opacity(scheme == .dark ? 0.35 : 0.12)],
                               center: .center, startRadius: 150, endRadius: 700)
            )
    }
}

/// A Lion panel: light gradient, 1px border, soft shadow.
struct LionPanel<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = LionTheme.palette(for: scheme)
        content
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(p.panelFill.swiftUI)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: p.panelBorder), lineWidth: 1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Color.white.opacity(p.isDark ? 0.08 : 0.8), lineWidth: 1)
                            .padding(1)
                    )
                    .shadow(color: .black.opacity(p.isDark ? 0.6 : 0.3), radius: 10, x: 0, y: 4)
            )
    }
}

/// Lion sheet for send failures: drops down from under the toolbar.
struct SendErrorSheet: View {
    let error: SendError
    let onDismiss: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = LionTheme.palette(for: scheme)
        let (title, message): (String, String) = {
            switch error {
            case .automationDenied:
                return ("Lion Messages needs permission to control Messages.",
                        "To send messages, Lion Messages asks Messages to deliver them for you. Allow it in System Settings > Privacy & Security > Automation, then try again.")
            case .scriptFailed(let detail):
                return ("Your message couldn’t be sent.", detail)
            }
        }()
        HStack(alignment: .top, spacing: 16) {
            CautionIcon().frame(width: 52, height: 48)
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(LionFont.swiftUI(13, bold: true))
                    .foregroundColor(Color(nsColor: p.panelHeadline))
                    .fixedSize(horizontal: false, vertical: true)
                Text(message)
                    .font(LionFont.swiftUI(11))
                    .foregroundColor(Color(nsColor: p.panelBody))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Spacer()
                    if error == .automationDenied {
                        Button("Not Now", action: onDismiss)
                            .buttonStyle(AquaButtonStyle(kind: .secondary))
                            .keyboardShortcut(.cancelAction)
                        Button("Open Automation Settings") {
                            NSWorkspace.shared.open(LionConstants.automationSettingsURL)
                            onDismiss()
                        }
                        .buttonStyle(AquaButtonStyle(kind: .primary, pulses: true))
                        .keyboardShortcut(.defaultAction)
                    } else {
                        Button("OK", action: onDismiss)
                            .buttonStyle(AquaButtonStyle(kind: .primary, pulses: true))
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(EdgeInsets(top: 18, leading: 18, bottom: 16, trailing: 18))
        .frame(width: 460)
        .background(
            ZStack(alignment: .top) {
                UnevenRoundedRectangleCompat(bottomRadius: 6)
                    .fill(p.panelFill.swiftUI)
                    .overlay(UnevenRoundedRectangleCompat(bottomRadius: 6).stroke(Color(nsColor: p.panelBorder), lineWidth: 1))
                // Inner shadow cast by the toolbar onto the sheet.
                LinearGradient(colors: [.black.opacity(p.isDark ? 0.5 : 0.2), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 6)
            }
            .shadow(color: .black.opacity(p.isDark ? 0.6 : 0.35), radius: 12, x: 0, y: 6)
        )
    }
}

/// Rectangle with only the bottom corners rounded (UnevenRoundedRectangle needs macOS 14).
struct UnevenRoundedRectangleCompat: Shape {
    var bottomRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(bottomRadius, rect.width / 2, rect.height / 2)
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// A yellow caution triangle in the 2011 style.
struct CautionIcon: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let triangle = Path { p in
                p.move(to: CGPoint(x: w / 2, y: 2))
                p.addLine(to: CGPoint(x: w - 2, y: h - 3))
                p.addLine(to: CGPoint(x: 2, y: h - 3))
                p.closeSubpath()
            }
            ZStack {
                triangle
                    .fill(LinearGradient(colors: [Color(nsColor: NSColor(hex: 0xfff38a)), Color(nsColor: NSColor(hex: 0xf5c400)),
                                                  Color(nsColor: NSColor(hex: 0xe8a800))],
                                         startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
                triangle.stroke(Color(nsColor: NSColor(hex: 0xa27400)), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
                Text("!")
                    .font(LionFont.swiftUI(h * 0.55, bold: true))
                    .foregroundColor(Color(nsColor: NSColor(hex: 0x2a2a2a)))
                    .offset(y: h * 0.1)
            }
        }
    }
}
