import AppKit
import MessagesModel
import SwiftUI

/// Shown instead of the conversation UI when chat.db can't be read.
struct PermissionView: View {
    let state: AccessState
    let onCheckAgain: () -> Void
    @Environment(\.colorScheme) private var scheme
    /// The panel fades in and grows from 97% the first time it appears.
    @State private var appeared = LionMotion.isDisabled

    var body: some View {
        ZStack {
            LinenBackground()
            LionPanel {
                content.padding(EdgeInsets(top: 26, leading: 30, bottom: 22, trailing: 30))
            }
            .frame(width: 548)
            .scaleEffect(appeared || LionMotion.reduceMotion ? 1 : LionMotion.panelStartScale)
            .opacity(appeared ? 1 : 0)
            .padding(24)
        }
        .onAppear {
            guard !appeared else { return }
            withAnimation(LionMotion.easeOut(LionMotion.panelAppear)) { appeared = true }
        }
    }

    private var palette: LionPalette { LionTheme.palette(for: scheme) }

    @ViewBuilder private var content: some View {
        switch state {
        case .databaseMissing:
            simple(headline: "No Messages database found",
                   body: "Lion Messages couldn’t find ~/Library/Messages/chat.db on this Mac. Open Messages, sign in, and send or receive a message, then check again.")
        case .failed(let detail):
            simple(headline: "Lion Messages couldn’t open your messages",
                   body: detail)
        case .granted, .fullDiskAccessDenied:
            fullDiskAccess
        }
    }

    private var fullDiskAccess: some View {
        let p = palette
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                PadlockIcon().frame(width: 56, height: 68)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Lion Messages needs Full Disk Access")
                        .font(LionFont.swiftUI(15, bold: true))
                        .foregroundColor(Color(nsColor: p.panelHeadline))
                        .lionEtched(p.etchShadow)
                    Text("Your messages are stored in ") + Text("~/Library/Messages/chat.db").font(LionFont.swiftUIMono(11)) +
                        Text(", which macOS protects. Lion Messages only reads it and never modifies it.")
                }
                .font(LionFont.swiftUI(12))
                .foregroundColor(Color(nsColor: p.panelBody))
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 9) {
                step(1, "Open System Settings > Privacy & Security > Full Disk Access.")
                step(2, "Turn on Lion Messages. (Use the + button to add it if it isn’t listed.)")
                step(3, "Quit and reopen Lion Messages.")
            }
            .padding(.top, 18)
            .padding(.leading, 74)

            HStack(spacing: 12) {
                Spacer()
                Button("Check Again", action: onCheckAgain)
                    .buttonStyle(AquaButtonStyle(kind: .secondary))
                Button("Open Full Disk Access Settings") {
                    NSWorkspace.shared.open(LionConstants.fullDiskAccessSettingsURL)
                }
                .buttonStyle(AquaButtonStyle(kind: .primary, pulses: true))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 22)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        let p = palette
        return HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text("\(n)")
                .font(LionFont.swiftUI(10, bold: true))
                .foregroundColor(.white)
                .frame(width: 17, height: 17)
                .background(
                    Circle().fill(LinearGradient(colors: [Color(nsColor: NSColor(hex: 0x8c97a6)), Color(nsColor: NSColor(hex: 0x5d6878))],
                                                 startPoint: .top, endPoint: .bottom))
                        .shadow(color: .white.opacity(p.isDark ? 0 : 0.8), radius: 0, x: 0, y: 1)
                )
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 4.5 }
            Text(text)
                .font(LionFont.swiftUI(12))
                .foregroundColor(Color(nsColor: p.panelBody))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func simple(headline: String, body: String) -> some View {
        let p = palette
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                CautionIcon().frame(width: 52, height: 48)
                VStack(alignment: .leading, spacing: 8) {
                    Text(headline)
                        .font(LionFont.swiftUI(15, bold: true))
                        .foregroundColor(Color(nsColor: p.panelHeadline))
                        .lionEtched(p.etchShadow)
                    Text(body)
                        .font(LionFont.swiftUI(12))
                        .foregroundColor(Color(nsColor: p.panelBody))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("Check Again", action: onCheckAgain)
                    .buttonStyle(AquaButtonStyle(kind: .primary, pulses: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 20)
        }
    }
}

/// A brushed-silver padlock, drawn the way 2011 system icons were.
struct PadlockIcon: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let bodyTop = h * 0.42
            ZStack(alignment: .top) {
                // Shackle.
                Path { p in
                    p.addArc(center: CGPoint(x: w / 2, y: bodyTop - h * 0.06), radius: w * 0.28,
                             startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                    p.addLine(to: CGPoint(x: w / 2 + w * 0.28, y: bodyTop + 4))
                    p.move(to: CGPoint(x: w / 2 - w * 0.28, y: bodyTop - h * 0.06))
                    p.addLine(to: CGPoint(x: w / 2 - w * 0.28, y: bodyTop + 4))
                }
                .stroke(LinearGradient(colors: [Color(nsColor: NSColor(hex: 0xf4f4f4)), Color(nsColor: NSColor(hex: 0x8e8e8e))],
                                       startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: w * 0.13, lineCap: .butt))
                .overlay(
                    Path { p in
                        p.addArc(center: CGPoint(x: w / 2, y: bodyTop - h * 0.06), radius: w * 0.28,
                                 startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                    }
                    .stroke(Color.black.opacity(0.25), lineWidth: 0.5)
                )
                // Body.
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(stops: [
                        .init(color: Color(nsColor: NSColor(hex: 0xfdfdfd)), location: 0),
                        .init(color: Color(nsColor: NSColor(hex: 0xd6d6d6)), location: 0.5),
                        .init(color: Color(nsColor: NSColor(hex: 0xbdbdbd)), location: 0.51),
                        .init(color: Color(nsColor: NSColor(hex: 0xe2e2e2)), location: 1),
                    ], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: NSColor(hex: 0x6e6e6e)), lineWidth: 1))
                    .overlay(
                        // Keyhole.
                        VStack(spacing: -2) {
                            Circle().fill(Color(nsColor: NSColor(hex: 0x3a3a3a))).frame(width: w * 0.16, height: w * 0.16)
                            Rectangle().fill(Color(nsColor: NSColor(hex: 0x3a3a3a))).frame(width: w * 0.07, height: h * 0.12)
                        }
                        .shadow(color: .white.opacity(0.8), radius: 0, x: 0, y: 1)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 2)
                    .frame(width: w * 0.86, height: h - bodyTop)
                    .offset(y: bodyTop)
            }
            .frame(width: w, height: h)
        }
    }
}
