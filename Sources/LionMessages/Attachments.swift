import AppKit
import Combine
import MessagesModel
import SwiftUI
import UniformTypeIdentifiers

// Sending files: the pending-attachment tray above the composer, the Attach button, drag and
// drop onto the conversation area, and pasting files or pictures. Never log paths or names.

/// A local file waiting to be sent with the draft.
struct PendingAttachment: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let isImage: Bool

    init(url: URL) {
        self.url = url
        isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    var name: String { url.lastPathComponent }
}

// MARK: - Pasteboard

/// Reads attachments from a drag or the general pasteboard: file URLs (Finder), or raw picture
/// data (a browser or Preview), which is written to a temporary file first.
enum AttachmentPasteboard {
    private static let imageTypes: [(NSPasteboard.PasteboardType, String)] = [
        (.png, "png"), (NSPasteboard.PasteboardType("public.jpeg"), "jpg"),
        (NSPasteboard.PasteboardType("public.heic"), "heic"), (NSPasteboard.PasteboardType("com.compuserve.gif"), "gif"),
        (.tiff, "tiff"),
    ]

    static var dragTypes: [NSPasteboard.PasteboardType] { [.fileURL] + imageTypes.map(\.0) }

    static func fileURLs(in pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    private static func imageType(in pasteboard: NSPasteboard) -> (NSPasteboard.PasteboardType, String)? {
        guard let type = pasteboard.availableType(from: imageTypes.map(\.0)) else { return nil }
        return imageTypes.first { $0.0 == type }
    }

    /// Whether the pasteboard holds something to attach. For paste, picture data only counts when
    /// there is no plain text (rich text copied from other apps often carries a picture of itself).
    static func hasAttachments(_ pasteboard: NSPasteboard, forPaste: Bool = false) -> Bool {
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return true }
        guard imageType(in: pasteboard) != nil else { return false }
        return !forPaste || pasteboard.availableType(from: [.string]) == nil
    }

    static func read(_ pasteboard: NSPasteboard) -> [URL] {
        let files = fileURLs(in: pasteboard)
        if !files.isEmpty { return files }
        guard let (type, ext) = imageType(in: pasteboard), var data = pasteboard.data(forType: type) else { return [] }
        var fileExtension = ext
        if type == .tiff, let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
            data = png
            fileExtension = "png"
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lion Messages Drops", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = folder.appendingPathComponent("Image.\(fileExtension)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url)
            return [url]
        } catch {
            return []
        }
    }
}

// MARK: - Drop target (the whole conversation pane)

/// The window's content view. It accepts file and picture drags anywhere over the transcript and
/// composer; the sidebar and toolbar refuse them. (The composer's text view handles drags over
/// itself the same way, see `ComposerTextView`.)
final class LionHostingView: NSHostingView<RootView> {
    weak var store: AppStore?

    required init(rootView: RootView) {
        super.init(rootView: rootView)
        registerForDraggedTypes(AttachmentPasteboard.dragTypes)
    }

    @MainActor required init?(coder: NSCoder) { fatalError("not used") }

    private func accepts(_ info: NSDraggingInfo) -> Bool {
        guard let store, store.canAcceptAttachments,
              AttachmentPasteboard.hasAttachments(info.draggingPasteboard) else { return false }
        let point = convert(info.draggingLocation, from: nil)
        let fromTop = isFlipped ? point.y : bounds.height - point.y
        let sidebar = store.sidebarDocked || store.sidebarOverlay ? SidebarController.width : 0
        return point.x >= sidebar && fromTop >= LionToolbarView.height
    }

    private func update(_ info: NSDraggingInfo) -> NSDragOperation {
        let ok = accepts(info)
        store?.setDropTargeted(ok)
        return ok ? .copy : []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { store?.setDropTargeted(false) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { accepts(sender) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        store?.setDropTargeted(false)
        guard accepts(sender), let store else { return false }
        let added = store.addAttachments(AttachmentPasteboard.read(sender.draggingPasteboard))
        if added { store.focusComposer.send() }
        return added
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) { store?.setDropTargeted(false) }
}

/// Lion's drop highlight: a soft blue inner ring and glow with a faint tint.
struct DropHighlight: View {
    private let blue = Color(nsColor: NSColor(hex: 0x7aacde))

    var body: some View {
        ZStack {
            blue.opacity(0.10)
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(blue.opacity(0.55), lineWidth: 6)
                .blur(radius: 3)
                .padding(2)
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(blue, lineWidth: 2.5)
                .padding(3)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Tray

/// Chips for the pending attachments, in a strip above the composer field.
struct AttachmentTray: View {
    static let height: CGFloat = 86
    @ObservedObject var store: AppStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(store.pendingAttachments) { attachment in
                    AttachmentChip(attachment: attachment) { store.removeAttachment(attachment.id) }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
        }
        .frame(height: Self.height)
    }
}

private struct AttachmentChip: View {
    let attachment: PendingAttachment
    let onRemove: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = LionTheme.palette(for: scheme)
        VStack(spacing: 5) {
            ZStack(alignment: .topLeading) {
                PendingThumbnail(attachment: attachment)
                    .frame(width: 48, height: 48)
                    .padding(EdgeInsets(top: 7, leading: 18, bottom: 0, trailing: 18))
                RemoveButton(action: onRemove)
                    .padding(.leading, 11)
            }
            Text(attachment.name)
                .font(LionFont.swiftUI(11))
                .foregroundColor(Color(nsColor: p.isDark ? NSColor(hex: 0xc9cdd2) : NSColor(hex: 0x3a3a3a)))
                .lionEtched(p.isDark ? LionTextShadow(color: NSColor(white: 0, alpha: 0.6), dy: -1)
                                     : LionTextShadow(color: NSColor(white: 1, alpha: 0.7), dy: 1))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 80)
        }
        .help(attachment.name)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(attachment.name)
    }
}

/// Small round gray "×", like Lion's search-field cancel button.
private struct RemoveButton: View {
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var pressed = false

    var body: some View {
        let p = LionTheme.palette(for: scheme)
        let fill = p.isDark ? NSColor(hex: 0x7c828a) : NSColor(hex: 0x8e8e8e)
        Button(action: action) {
            ZStack {
                Circle().fill(LinearGradient(colors: [Color(nsColor: fill.blended(withFraction: 0.25, of: .white) ?? fill),
                                                      Color(nsColor: fill)], startPoint: .top, endPoint: .bottom))
                Circle().strokeBorder(Color.white.opacity(p.isDark ? 0.5 : 0.95), lineWidth: 1.2)
                Path { path in
                    path.move(to: CGPoint(x: 5.2, y: 5.2)); path.addLine(to: CGPoint(x: 10.8, y: 10.8))
                    path.move(to: CGPoint(x: 10.8, y: 5.2)); path.addLine(to: CGPoint(x: 5.2, y: 10.8))
                }
                .stroke(Color.white, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            }
            .frame(width: 16, height: 16)
            .shadow(color: .black.opacity(p.isDark ? 0.6 : 0.35), radius: 1, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .help("Remove")
        .accessibilityLabel("Remove Attachment")
    }
}

/// 48 pt picture thumbnail (decoded off the main thread through the shared media cache), or the
/// file's Finder icon.
private struct PendingThumbnail: View {
    let attachment: PendingAttachment
    @StateObject private var loader = ThumbnailLoader()
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = LionTheme.palette(for: scheme)
        Group {
            if attachment.isImage {
                ZStack {
                    Color(nsColor: p.mediaPlaceholder)
                    if let image = loader.image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 48, height: 48)
                            .clipped()
                    }
                }
                .overlay(Rectangle().strokeBorder(Color(nsColor: p.mediaBorder), lineWidth: 1))
                .shadow(color: .black.opacity(p.isDark ? 0.5 : 0.25), radius: 1, x: 0, y: 1)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: attachment.url.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 48, height: 48)
            }
        }
        .onAppear { if attachment.isImage { loader.load(attachment) } }
        .onDisappear { loader.cancel() }
    }
}

@MainActor
private final class ThumbnailLoader: ObservableObject {
    @Published var image: CGImage?
    private var token: MediaLoader.Token?

    func load(_ attachment: PendingAttachment) {
        guard image == nil, token == nil else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let source = MediaGeometry.pixelSize(of: attachment.url) ?? .zero
        let request = MediaLoader.Request(
            id: "pending-\(attachment.id.uuidString)", url: attachment.url, kind: .image,
            maxPixel: MediaLoader.maxPixel(source: source, display: CGSize(width: 48, height: 48), scale: scale))
        if let cached = MediaLoader.shared.cached(request) {
            image = cached
            return
        }
        token = MediaLoader.shared.load(request) { [weak self] cg in
            self?.token = nil
            self?.image = cg
        }
    }

    func cancel() {
        if let token { MediaLoader.shared.cancel(token) }
        token = nil
    }
}

// MARK: - Composer controls

/// The paperclip button left of the composer field.
struct AttachButtonRepresentable: NSViewRepresentable {
    let store: AppStore
    let isEnabled: Bool

    func makeNSView(context: Context) -> LionTexturedButton {
        LionTexturedButton(glyph: .paperclip, toolTip: "Attach Files…") { [weak store] in store?.requestAttachPanel() }
    }

    func updateNSView(_ nsView: LionTexturedButton, context: Context) {
        nsView.isEnabled = isEnabled
    }
}

/// The classic twelve-spoke gray spinner.
final class LionSpinnerView: LionView {
    private var step = 0
    private var timer: Timer?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil, !LionMotion.isDisabled else { return }
        let t = Timer(timeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.step = (self.step + 1) % 12
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = palette
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let outer = min(bounds.width, bounds.height) / 2 - 0.5
        let inner = outer * 0.48
        let base = p.isDark ? NSColor(white: 0.85, alpha: 1) : NSColor(white: 0.25, alpha: 1)
        for i in 0..<12 {
            // The head spoke is darkest; the trail fades behind it.
            let age = (step - i + 12) % 12
            base.withAlphaComponent(max(0.15, 1 - CGFloat(age) / 11)).setStroke()
            let angle = CGFloat(i) / 12 * 2 * .pi - .pi / 2
            let path = NSBezierPath()
            path.move(to: NSPoint(x: c.x + cos(angle) * inner, y: c.y + sin(angle) * inner))
            path.line(to: NSPoint(x: c.x + cos(angle) * outer, y: c.y + sin(angle) * outer))
            path.lineWidth = max(1.4, outer * 0.24)
            path.lineCapStyle = .round
            path.stroke()
        }
    }
}

struct LionSpinner: NSViewRepresentable {
    func makeNSView(context: Context) -> LionSpinnerView {
        let view = LionSpinnerView()
        view.setAccessibilityRole(.progressIndicator)
        view.setAccessibilityLabel("Sending")
        return view
    }

    func updateNSView(_ nsView: LionSpinnerView, context: Context) {}
}
