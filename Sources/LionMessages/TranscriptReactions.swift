import AppKit
import MessagesModel

/// Tapbacks on a bubble: a small glossy iChat-style pill on the bubble's top corner (the outer
/// corner, as in Messages) listing each reaction once, with a count when several people chose
/// it. It turns blue when one of them is yours.
enum ReactionBadge {
    static let height: CGFloat = 20
    /// How far the badge sits over the bubble; the rest needs room above the row's content.
    static let overlap: CGFloat = 7
    static var headroom: CGFloat { height - overlap }
    static let padX: CGFloat = 6
    static let shadowRoom: CGFloat = 2

    private static let symbolFont = NSFont.systemFont(ofSize: 11)
    private static let countFont = LionFont.bold(10)

    struct Group: Equatable {
        var kind: Reaction.Kind
        var count: Int
        var includesMe: Bool
    }

    /// One entry per kind, in the order each first appeared.
    static func groups(_ reactions: [Reaction]) -> [Group] {
        var out: [Group] = []
        for r in reactions {
            if let i = out.firstIndex(where: { $0.kind == r.kind }) {
                out[i].count += 1
                out[i].includesMe = out[i].includesMe || r.isFromMe
            } else {
                out.append(Group(kind: r.kind, count: 1, includesMe: r.isFromMe))
            }
        }
        return out
    }

    static func label(_ groups: [Group], textColor: NSColor) -> NSAttributedString {
        let s = NSMutableAttributedString()
        for (n, g) in groups.enumerated() {
            if n > 0 { s.append(NSAttributedString(string: " ", attributes: [.font: symbolFont])) }
            s.append(NSAttributedString(string: g.kind.symbol, attributes: [.font: symbolFont]))
            if g.count > 1 {
                s.append(NSAttributedString(string: "\u{2009}\(g.count)", attributes: [
                    .font: countFont, .foregroundColor: textColor, .baselineOffset: 1,
                ]))
            }
        }
        return s
    }

    static func width(_ reactions: [Reaction]) -> CGFloat {
        ceil(label(groups(reactions), textColor: .black).size().width) + 2 * padX
    }

    /// "Loved by Maya and you · Liked by Jonah" (tooltip and VoiceOver).
    static func summary(_ reactions: [Reaction]) -> String {
        var byKind: [(Reaction.Kind, [String])] = []
        for r in reactions {
            let who = r.isFromMe ? "you" : (r.senderName ?? r.senderHandle ?? "someone")
            if let i = byKind.firstIndex(where: { $0.0 == r.kind }) { byKind[i].1.append(who) } else { byKind.append((r.kind, [who])) }
        }
        return byKind.map { kind, names in
            let list = names.count <= 2 ? names.joined(separator: " and ")
                : names.dropLast().joined(separator: ", ") + " and " + names.last!
            return "\(kind.verb) by \(list)"
        }.joined(separator: " · ")
    }
}

final class ReactionBadgeView: NSView {
    var reactions: [Reaction] = [] {
        didSet {
            guard reactions != oldValue else { return }
            needsDisplay = true
            toolTip = ReactionBadge.summary(reactions)
        }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let p = LionTheme.palette(for: effectiveAppearance)
        let groups = ReactionBadge.groups(reactions)
        guard !groups.isEmpty else { return }
        let mine = groups.contains { $0.includesMe }
        let body = NSRect(x: 0.5, y: 0.5, width: bounds.width - 1, height: ReactionBadge.height - 1)
        let shape = NSBezierPath(roundedRect: body, xRadius: body.height / 2, yRadius: body.height / 2)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = p.bubbleShadow
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        (mine ? p.outgoingBubble.stops.last!.0 : p.cardFill.stops.last!.0).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        (mine ? p.outgoingBubble : p.cardFill).drawVertical(in: shape, flipped: true)
        // Gloss on the upper half, like the bubbles.
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        LionGradient(p.bubbleGloss, p.bubbleGloss.withAlphaComponent(0))
            .drawVertical(in: NSRect(x: body.minX, y: body.minY, width: body.width, height: body.height / 2), flipped: true)
        NSGraphicsContext.restoreGraphicsState()
        (mine ? p.outgoingBorder : p.cardBorder).setStroke()
        shape.lineWidth = 1
        shape.stroke()

        let label = ReactionBadge.label(groups, textColor: mine ? p.outgoingText : p.incomingText)
        let size = label.size()
        label.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (ReactionBadge.height - size.height) / 2))
    }
}
