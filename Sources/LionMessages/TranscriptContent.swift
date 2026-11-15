import AppKit
import MessagesModel
import UniformTypeIdentifiers

// What a message shows (text bubbles, pictures, files, link cards) and where each piece goes.
// Everything here is measured synchronously from cached text metrics and header-only media sizes,
// so a row's height is final the moment the table asks for it.

/// One gel bubble's text.
struct BubbleText: Hashable {
    enum Style: Hashable { case body, placeholder }
    struct Link: Hashable {
        let location: Int
        let length: Int
        let url: URL
    }

    let messageID: Int64
    /// 0 = the message text, 1 = the "not downloaded" note.
    let slot: Int
    let string: String
    let style: Style
    let links: [Link]

    func attributed(isFromMe: Bool, palette p: LionPalette) -> NSAttributedString {
        if style == .placeholder {
            return NSAttributedString(string: string, attributes: [
                .font: LionFont.oblique(12), .foregroundColor: p.attachmentText,
            ])
        }
        let s = NSMutableAttributedString(string: string, attributes: [
            .font: LionFont.regular(12), .foregroundColor: isFromMe ? p.outgoingText : p.incomingText,
        ])
        for link in links {
            s.addAttribute(.link, value: link.url, range: NSRange(location: link.location, length: link.length))
        }
        return s
    }
}

enum ContentPart: Hashable {
    case text(BubbleText)
    /// An inline picture, sticker or video thumbnail; `pixelSize` is display-oriented.
    case media(MessageAttachment, pixelSize: CGSize, isVideo: Bool)
    case file(MessageAttachment, url: URL)
    case more(Int)
    /// `imagePixelSize` is nil when the card has no (readable) picture.
    case card(LinkPreview, messageID: Int64, imagePixelSize: CGSize?)

    var viewKind: Int {
        switch self {
        case .text: return 0
        case .media: return 1
        case .file: return 2
        case .more: return 3
        case .card: return 4
        }
    }
}

@MainActor
enum ContentBuilder {
    static let maxVisibleAttachments = 10
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func links(in string: String) -> [BubbleText.Link] {
        guard let detector, string.count < 20_000 else { return [] }
        let ns = string as NSString
        return detector.matches(in: string, range: NSRange(location: 0, length: ns.length)).compactMap { r in
            guard let url = r.url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return BubbleText.Link(location: r.range.location, length: r.range.length, url: url)
        }
    }

    static func build(_ m: Message) -> [ContentPart] {
        var media: [ContentPart] = []
        var missing: [MessageAttachment] = []
        for a in m.attachments {
            guard let url = a.fileURL else { missing.append(a); continue }
            switch a.kind {
            case .image:
                if let size = MediaGeometry.pixelSize(of: url) {
                    media.append(.media(a, pixelSize: size, isVideo: false))
                } else {
                    media.append(.file(a, url: url))
                }
            case .video:
                media.append(.media(a, pixelSize: MediaGeometry.videoSize(of: url) ?? CGSize(width: 4, height: 3),
                                    isVideo: true))
            case .audio, .other:
                media.append(.file(a, url: url))
            }
        }
        var parts: [ContentPart] = Array(media.prefix(maxVisibleAttachments))
        if media.count > maxVisibleAttachments { parts.append(.more(media.count - maxVisibleAttachments)) }
        if !missing.isEmpty {
            parts.append(.text(BubbleText(messageID: m.id, slot: 1, string: missingLabel(missing), style: .placeholder, links: [])))
        }

        var card: ContentPart?
        if let preview = m.linkPreview {
            let imageSize = preview.imageFileURL.flatMap(MediaGeometry.pixelSize(of:))
            let hasTitle = !(preview.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            if hasTitle || imageSize != nil {
                card = .card(preview, messageID: m.id, imagePixelSize: imageSize)
            }
        }

        let isPlaceholder = m.text == LionConstants.attachmentPlaceholder
        if isPlaceholder {
            if parts.isEmpty && card == nil {
                if let preview = m.linkPreview {
                    // A URL balloon whose preview has nothing to show: the plain clickable link.
                    let s = preview.url.absoluteString
                    parts.append(.text(BubbleText(messageID: m.id, slot: 0, string: s, style: .body, links: links(in: s))))
                } else {
                    parts.append(.text(BubbleText(messageID: m.id, slot: 0, string: m.text, style: .placeholder, links: [])))
                }
            }
        } else {
            let found = links(in: m.text)
            let trimmed = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let onlyURL = card != nil && found.count == 1 && (m.text as NSString)
                .substring(with: NSRange(location: found[0].location, length: found[0].length)) == trimmed
            if !onlyURL {
                parts.append(.text(BubbleText(messageID: m.id, slot: 0, string: m.text, style: .body, links: found)))
            }
        }
        if let card { parts.append(card) }
        return parts
    }

    private static func missingLabel(_ list: [MessageAttachment]) -> String {
        if list.count > 1 { return "[\(list.count) attachments not downloaded]" }
        let a = list[0]
        switch a.kind {
        case .image: return a.isSticker ? "[Sticker not downloaded]" : "[Image not downloaded]"
        case .video: return "[Video not downloaded]"
        case .audio: return "[Audio not downloaded]"
        case .other:
            let ext = (a.displayName as NSString?)?.pathExtension ?? ""
            return ext.isEmpty ? "[Attachment not downloaded]" : "[\(ext.uppercased()) file not downloaded]"
        }
    }
}

/// Text measurement for bubbles, cached per bubble (and per width for wrapped text).
@MainActor
final class BubbleMetrics {
    nonisolated static let padX: CGFloat = 11
    nonisolated static let padY: CGFloat = 5
    nonisolated static let sideMargin: CGFloat = 14
    /// Extra room under the bubble for its 1px drop shadow.
    nonisolated static let shadowRoom: CGFloat = 2

    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer()
    private var natural: [Key: NSSize] = [:]
    private var wrapped: [WrapKey: NSSize] = [:]

    private struct Key: Hashable { let id: Int64; let slot: Int }
    private struct WrapKey: Hashable { let key: Key; let width: Int }

    init() {
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
    }

    private func measure(_ t: BubbleText, width: CGFloat) -> NSSize {
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        storage.setAttributedString(t.attributed(isFromMe: false, palette: .light))
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        return NSSize(width: ceil(used.width), height: ceil(used.height))
    }

    /// Size of the text block and the text container width to lay it out with.
    func textLayout(for t: BubbleText, maxTextWidth: CGFloat) -> (size: NSSize, containerWidth: CGFloat) {
        let key = Key(id: t.messageID, slot: t.slot)
        let nat = natural[key] ?? {
            let s = measure(t, width: 100_000)
            natural[key] = s
            return s
        }()
        if nat.width <= maxTextWidth { return (nat, nat.width + 1) }
        let wrapKey = WrapKey(key: key, width: Int(maxTextWidth))
        let s = wrapped[wrapKey] ?? {
            let s = measure(t, width: CGFloat(wrapKey.width))
            wrapped[wrapKey] = s
            return s
        }()
        return (s, CGFloat(wrapKey.width))
    }

    func trimCache(keeping ids: Set<Int64>) {
        if natural.count > 2000 { natural = natural.filter { ids.contains($0.key.id) } }
        // Live resizing creates one entry per width; old widths are cheap to recompute.
        if wrapped.count > 4000 { wrapped.removeAll(keepingCapacity: true) }
    }
}

/// Where the buddy picture column is: not at all (pictures off), reserved but empty (an earlier
/// bubble in a run), or showing the picture (the run's last bubble).
enum AvatarSlot: Hashable {
    case none, reserved, shown
}

enum BuddyMetrics {
    static let size: CGFloat = 32
    static let gap: CGFloat = 6
    static var column: CGFloat { size + gap }
}

/// A card's internal measurements at one width.
struct CardLayout {
    static let padX: CGFloat = 9
    static let maxImageHeight: CGFloat = 160
    static let footerHeight: CGFloat = 16
    static let iconSize: CGFloat = 16

    let width: CGFloat
    let imageHeight: CGFloat
    let title: String?
    let titleHeight: CGFloat
    let summary: String?
    let summaryHeight: CGFloat
    let site: String
    let height: CGFloat

    var titleY: CGFloat { (imageHeight > 0 ? imageHeight + 1 : 0) + 7 }
    var summaryY: CGFloat { titleY + titleHeight + (titleHeight > 0 ? 2 : 0) }
    var footerY: CGFloat { summaryY + summaryHeight + (summaryHeight > 0 || titleHeight > 0 ? 5 : 0) }

    static func titleAttributes(_ color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: LionFont.bold(12), .foregroundColor: color, .paragraphStyle: wrapping]
    }

    static func summaryAttributes(_ color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: LionFont.regular(11), .foregroundColor: color, .paragraphStyle: wrapping]
    }

    static func siteAttributes(_ color: NSColor) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        return [.font: LionFont.regular(10.5), .foregroundColor: color, .paragraphStyle: p]
    }

    private static let wrapping: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byWordWrapping
        return p
    }()

    static let drawOptions: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine]

    /// Height of `string` wrapped at `width`, clamped to `maxLines` lines.
    private static func clampedHeight(_ string: String, attributes: [NSAttributedString.Key: Any],
                                      width: CGFloat, maxLines: Int) -> CGFloat {
        let opts: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let bound = NSSize(width: width, height: .greatestFiniteMagnitude)
        let full = NSAttributedString(string: string, attributes: attributes).boundingRect(with: bound, options: opts).height
        let probe = Array(repeating: "Ag", count: maxLines).joined(separator: "\n")
        let clamp = NSAttributedString(string: probe, attributes: attributes).boundingRect(with: bound, options: opts).height
        return ceil(min(full, clamp))
    }

    static func make(_ preview: LinkPreview, imagePixelSize: CGSize?, width: CGFloat) -> CardLayout {
        let inner = width - 2 * padX
        var imageHeight: CGFloat = 0
        if let s = imagePixelSize, s.width > 0 {
            imageHeight = min(maxImageHeight, round(width * s.height / s.width))
        }
        let title = preview.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let summary = preview.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let titleHeight = title.map { clampedHeight($0, attributes: titleAttributes(.black), width: inner, maxLines: 2) } ?? 0
        let summaryHeight = summary.map { clampedHeight($0, attributes: summaryAttributes(.black), width: inner, maxLines: 2) } ?? 0
        var site = preview.siteName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? preview.url.host ?? preview.url.absoluteString
        if site.hasPrefix("www.") { site.removeFirst(4) }
        var layout = CardLayout(width: width, imageHeight: imageHeight, title: title, titleHeight: titleHeight,
                                summary: summary, summaryHeight: summaryHeight, site: site, height: 0)
        layout = CardLayout(width: width, imageHeight: imageHeight, title: title, titleHeight: titleHeight,
                            summary: summary, summaryHeight: summaryHeight, site: site,
                            height: layout.footerY + footerHeight + 7)
        return layout
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// The compact file bubble's measurements.
enum FileBubbleMetrics {
    static let height: CGFloat = 44
    static let iconSize: CGFloat = 32
    static let leftPad: CGFloat = 8
    static let iconGap: CGFloat = 8
    static let rightPad: CGFloat = 13
    static var textX: CGFloat { leftPad + iconSize + iconGap }

    static func name(_ a: MessageAttachment, url: URL) -> String {
        a.displayName?.nilIfEmpty ?? url.lastPathComponent
    }

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    static func detail(_ a: MessageAttachment, url: URL) -> String {
        let type = (a.uti.flatMap { UTType($0) } ?? UTType(filenameExtension: url.pathExtension))?.localizedDescription
        let size = a.byteCount.map { byteFormatter.string(fromByteCount: $0) }
        return [size, type].compactMap { $0 }.joined(separator: " – ").nilIfEmpty ?? "File"
    }

    static let nameFont = LionFont.regular(12)
    static let detailFont = LionFont.regular(10.5)

    static func width(_ a: MessageAttachment, url: URL, maxWidth: CGFloat) -> CGFloat {
        let nameW = ceil(NSAttributedString(string: name(a, url: url), attributes: [.font: nameFont]).size().width)
        let detailW = ceil(NSAttributedString(string: detail(a, url: url), attributes: [.font: detailFont]).size().width)
        let textW = min(max(nameW, detailW), max(40, maxWidth - textX - rightPad))
        return textX + textW + rightPad
    }
}

/// A message's parts placed in its row. Horizontal positions are offsets from the sender's side;
/// the cell turns them into frames for its actual width.
struct MessageGeometry {
    struct Placed {
        let part: ContentPart
        /// Body size (the visible bubble/picture/card, without shadow room).
        let size: NSSize
        let y: CGFloat
        var text: (size: NSSize, containerWidth: CGFloat)?
        var card: CardLayout?
    }

    static let partSpacing: CGFloat = 4

    let isFromMe: Bool
    let parts: [Placed]
    /// Distance from the sender's edge of the cell to the content.
    let sideInset: CGFloat
    /// Top of the buddy picture when it is shown in this row.
    let avatarY: CGFloat?
    let rowHeight: CGFloat
    /// Width of the tapback badge (0 = no reactions).
    var reactionWidth: CGFloat = 0

    func bodyRect(_ i: Int, cellWidth: CGFloat) -> NSRect {
        let p = parts[i]
        let x = isFromMe ? cellWidth - sideInset - p.size.width : sideInset
        return NSRect(x: x, y: p.y, width: p.size.width, height: p.size.height)
    }

    /// The part's view frame: one point around the body, plus room for the drop shadow.
    func viewFrame(_ i: Int, cellWidth: CGFloat) -> NSRect {
        let b = bodyRect(i, cellWidth: cellWidth)
        if case .more = parts[i].part { return b }
        return NSRect(x: b.minX - 1, y: b.minY - 1, width: b.width + 2, height: b.height + 1 + BubbleMetrics.shadowRoom)
    }

    /// The tapback badge: over the first part's top corner on the far side from the sender's
    /// edge (top right of an incoming bubble, top left of an outgoing one).
    func reactionFrame(cellWidth: CGFloat) -> NSRect? {
        guard reactionWidth > 0, !parts.isEmpty else { return nil }
        let b = bodyRect(0, cellWidth: cellWidth)
        let w = reactionWidth
        var x = isFromMe ? b.minX - w + 12 : b.maxX - 12
        x = min(max(x, 2), cellWidth - w - 2)
        return NSRect(x: x, y: b.minY - ReactionBadge.headroom, width: w,
                      height: ReactionBadge.height + ReactionBadge.shadowRoom)
    }

    func avatarFrame(cellWidth: CGFloat) -> NSRect? {
        guard let y = avatarY else { return nil }
        let s = BuddyMetrics.size
        let x = isFromMe ? cellWidth - BubbleMetrics.sideMargin - s : BubbleMetrics.sideMargin
        return NSRect(x: x - 1, y: y - 1, width: s + 2, height: s + 1 + BubbleMetrics.shadowRoom)
    }

    /// Everything the row draws (parts and picture), for the arrival animation.
    func contentFrame(cellWidth: CGFloat) -> NSRect {
        var r = parts.indices.map { viewFrame($0, cellWidth: cellWidth) }.reduce(NSRect.null) { $0.union($1) }
        if let a = avatarFrame(cellWidth: cellWidth) { r = r.union(a) }
        if let b = reactionFrame(cellWidth: cellWidth) { r = r.union(b) }
        return r.integral
    }
}

/// Builds and caches content and geometry per message.
@MainActor
final class TranscriptLayout {
    let metrics = BubbleMetrics()
    private var contents: [Int64: (message: Message, parts: [ContentPart])] = [:]
    private var cards: [CardKey: CardLayout] = [:]
    private var geometries: [GeometryKey: MessageGeometry] = [:]

    private struct CardKey: Hashable { let id: Int64; let width: Int }
    private struct GeometryKey: Hashable {
        let id: Int64
        let width: Int
        let gap: Int
        let slot: AvatarSlot
    }

    func parts(for m: Message) -> [ContentPart] {
        if let c = contents[m.id], c.message == m { return c.parts }
        let parts = ContentBuilder.build(m)
        contents[m.id] = (m, parts)
        return parts
    }

    /// True when the message is a single plain text bubble (laid out exactly as before rich content).
    func isPlain(_ m: Message) -> Bool {
        let p = parts(for: m)
        if p.count == 1, case .text = p[0] { return true }
        return false
    }

    static func maxTextWidth(columnWidth: CGFloat, slot: AvatarSlot) -> CGFloat {
        let avatar = slot == .none ? 0 : BuddyMetrics.column
        return max(60, floor((columnWidth - avatar) * 0.65) - 2 * BubbleMetrics.padX)
    }

    func geometry(for m: Message, columnWidth: CGFloat, gap: CGFloat, slot: AvatarSlot) -> MessageGeometry {
        let key = GeometryKey(id: m.id, width: Int((columnWidth * 4).rounded()), gap: Int((gap * 4).rounded()), slot: slot)
        if let g = geometries[key], contents[m.id]?.message == m { return g }
        let g = makeGeometry(m, columnWidth: columnWidth, gap: gap, slot: slot)
        geometries[key] = g
        return g
    }

    private func makeGeometry(_ m: Message, columnWidth: CGFloat, gap: CGFloat, slot: AvatarSlot) -> MessageGeometry {
        let textMax = Self.maxTextWidth(columnWidth: columnWidth, slot: slot)
        let bubbleMax = textMax + 2 * BubbleMetrics.padX
        let mediaMax = min(260, bubbleMax)
        let cardWidth = min(300, bubbleMax)
        var placed: [MessageGeometry.Placed] = []
        var y: CGFloat = 0
        for part in parts(for: m) {
            if !placed.isEmpty { y += MessageGeometry.partSpacing }
            var item: MessageGeometry.Placed
            switch part {
            case .text(let t):
                let layout = metrics.textLayout(for: t, maxTextWidth: textMax)
                item = .init(part: part, size: NSSize(width: layout.size.width + 2 * BubbleMetrics.padX,
                                                      height: layout.size.height + 2 * BubbleMetrics.padY), y: y)
                item.text = layout
            case .media(let a, let pixelSize, let isVideo):
                let limit = a.isSticker ? min(120, mediaMax) : mediaMax
                item = .init(part: part, size: Self.fit(pixelSize, in: limit, upscale: isVideo), y: y)
            case .file(let a, let url):
                item = .init(part: part, size: NSSize(width: FileBubbleMetrics.width(a, url: url, maxWidth: bubbleMax),
                                                      height: FileBubbleMetrics.height), y: y)
            case .more(let n):
                let w = ceil(NSAttributedString(string: MoreView.label(n), attributes: [.font: MoreView.font]).size().width)
                item = .init(part: part, size: NSSize(width: w + 2, height: 14), y: y)
            case .card(let preview, let id, let imageSize):
                let key = CardKey(id: id, width: Int(cardWidth))
                let layout = cards[key] ?? CardLayout.make(preview, imagePixelSize: imageSize, width: cardWidth)
                cards[key] = layout
                item = .init(part: part, size: NSSize(width: layout.width, height: layout.height), y: y)
                item.card = layout
            }
            placed.append(item)
            y += item.size.height
        }
        let total = y
        // Room above the first part for the tapback badge.
        let headroom = m.reactions.isEmpty ? 0 : ReactionBadge.headroom
        let top = slot == .shown ? max(gap + headroom, BuddyMetrics.size - total) : gap + headroom
        let shifted = placed.map { p -> MessageGeometry.Placed in
            var q = MessageGeometry.Placed(part: p.part, size: p.size, y: p.y + top)
            q.text = p.text
            q.card = p.card
            return q
        }
        let side = BubbleMetrics.sideMargin + (slot == .none ? 0 : BuddyMetrics.column)
        var g = MessageGeometry(isFromMe: m.isFromMe, parts: shifted, sideInset: side,
                                avatarY: slot == .shown ? top + total - BuddyMetrics.size : nil,
                                rowHeight: top + total + BubbleMetrics.shadowRoom)
        if !m.reactions.isEmpty { g.reactionWidth = ReactionBadge.width(m.reactions) }
        return g
    }

    /// Aspect-fit within a `limit`-point square; pictures are never enlarged (videos may be).
    static func fit(_ s: CGSize, in limit: CGFloat, upscale: Bool) -> NSSize {
        guard s.width > 0, s.height > 0 else { return NSSize(width: limit, height: round(limit * 0.75)) }
        var scale = min(limit / s.width, limit / s.height)
        if !upscale { scale = min(1, scale) }
        return NSSize(width: max(1, round(s.width * scale)), height: max(1, round(s.height * scale)))
    }

    func trimCache(keeping ids: Set<Int64>) {
        metrics.trimCache(keeping: ids)
        if contents.count > 2000 { contents = contents.filter { ids.contains($0.key) } }
        if geometries.count > 6000 { geometries.removeAll(keepingCapacity: true) }
        if cards.count > 2000 { cards.removeAll(keepingCapacity: true) }
    }
}
