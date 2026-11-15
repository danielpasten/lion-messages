import AppKit
import Combine
import MessagesModel
import SwiftUI

/// The bottom bar: a sunken Aqua text field that grows to five lines, and a glossy Send button.
struct ComposerView: View {
    @ObservedObject var store: AppStore
    @Environment(\.colorScheme) private var scheme
    @State private var fieldHeight: CGFloat = ComposerFieldView.height(forTextHeight: 0)
    @State private var sendFlash = false

    var body: some View {
        let p = LionTheme.palette(for: scheme)
        let halo = ComposerFieldView.halo
        HStack(alignment: .bottom, spacing: 6) {
            // The field view is `halo` larger on every side (room for the focus ring animation)
            // without taking up more layout space.
            ComposerFieldRepresentable(store: store, height: $fieldHeight)
                .frame(height: fieldHeight + 2 * halo)
                .padding(-halo)
            Button("Send") { store.sendDraft() }
                .buttonStyle(AquaButtonStyle(kind: .primary, forcePressed: sendFlash))
                .disabled(!store.canSend && !sendFlash)
                .padding(.bottom, ComposerFieldView.ringMargin + 2)
        }
        .onReceive(store.didStartSend) {
            // Return-to-send: show the button pressed for a moment, as a click would.
            sendFlash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + LionMotion.duration(LionMotion.sendFlash)) { sendFlash = false }
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background(p.composerBar.swiftUI)
        .overlay(alignment: .top) {
            Rectangle().fill(Color(nsColor: p.composerTopLine)).frame(height: 1)
        }
    }
}

/// Sunken field drawn by hand around an NSTextView (SwiftUI can't do Return-to-send + growth well).
final class ComposerFieldView: LionView {
    static let ringMargin: CGFloat = 4
    static let insetX: CGFloat = 8
    static let insetY: CGFloat = 4
    static let font = LionFont.regular(12)
    static let lineHeight: CGFloat = NSLayoutManager().defaultLineHeight(for: font)
    static let maxLines: CGFloat = 5
    /// Extra drawing room on every side for the focus ring's contracting animation.
    static let halo = LionMotion.focusRingOutset

    static func height(forTextHeight h: CGFloat) -> CGFloat {
        let text = min(max(h, lineHeight), lineHeight * maxLines)
        return ceil(text + 2 * insetY + 2 * ringMargin + 2)
    }

    let scrollView = LionScrollView()
    let textView = ComposerTextView()
    var isFocused = false { didSet { ring.setFocused(isFocused) } }
    private let ring = LionFocusRing()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.drawsBackground = false
        scrollView.documentView = textView
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = Self.font
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.focusRingType = .none
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.onFocusChange = { [weak self] focused in self?.isFocused = focused }
        ring.onChange = { [weak self] in self?.needsDisplay = true }
        addSubview(scrollView)
        appearanceDidChange()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func appearanceDidChange() {
        let p = palette
        textView.textColor = p.fieldText
        textView.insertionPointColor = p.fieldText
        textView.selectedTextAttributes = [.backgroundColor: p.textSelection]
        textView.typingAttributes = [.font: Self.font, .foregroundColor: p.fieldText]
        textView.needsDisplay = true
    }

    private var fieldRect: NSRect { bounds.insetBy(dx: Self.ringMargin + Self.halo, dy: Self.ringMargin + Self.halo) }

    /// The halo is only for drawing; clicks there belong to whatever is underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.insetBy(dx: Self.halo, dy: Self.halo).contains(local) else { return nil }
        return super.hitTest(point)
    }

    override func layout() {
        super.layout()
        let f = fieldRect
        scrollView.frame = NSRect(x: f.minX + Self.insetX, y: f.minY + Self.insetY + 1,
                                  width: f.width - 2 * Self.insetX + 4, height: f.height - 2 * Self.insetY - 1)
        textView.frame.size.width = scrollView.contentSize.width
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(textView)
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = palette
        let f = fieldRect
        let radius: CGFloat = 4

        // Light ledge under the field so it looks pressed into the bar.
        NSColor(white: 1, alpha: p.isDark ? 0.07 : 0.55).setFill()
        NSBezierPath(roundedRect: f.offsetBy(dx: 0, dy: 1), xRadius: radius, yRadius: radius).fill()

        if ring.alpha > 0 {
            // Soft blue Aqua focus glow, ~3px (larger and fainter while it contracts).
            for (inset, alpha) in [(3.0, 0.35), (2.0, 0.6), (1.0, 0.9)] as [(CGFloat, CGFloat)] {
                let o = inset + ring.outset
                p.focusRing.withAlphaComponent(alpha * ring.alpha).setFill()
                NSBezierPath(roundedRect: f.insetBy(dx: -o, dy: -o), xRadius: radius + o, yRadius: radius + o).fill()
            }
        }

        let shape = NSBezierPath(roundedRect: f, xRadius: radius, yRadius: radius)
        p.fieldBackground.setFill()
        shape.fill()

        // Inner top shadow.
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        LionGradient(NSColor(white: 0, alpha: p.isDark ? 0.55 : 0.16), NSColor(white: 0, alpha: 0))
            .drawVertical(in: NSRect(x: f.minX, y: f.minY, width: f.width, height: 4), flipped: true)
        NSGraphicsContext.restoreGraphicsState()

        let border = NSBezierPath(roundedRect: f.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
        p.fieldBorder.lionMix(p.focusRing.blended(withFraction: 0.35, of: p.fieldBorder) ?? p.fieldBorder, ring.alpha).setStroke()
        border.lineWidth = 1
        border.stroke()
        // Slightly darker top edge.
        p.fieldTopEdge.setFill()
        NSRect(x: f.minX + radius, y: f.minY, width: f.width - 2 * radius, height: 1).fill()
    }

    var textHeight: CGFloat {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return Self.lineHeight }
        lm.ensureLayout(for: tc)
        var h = lm.usedRect(for: tc).height
        // A trailing newline isn't counted in usedRect.
        if textView.string.hasSuffix("\n") { h += Self.lineHeight }
        return h
    }
}

final class ComposerTextView: NSTextView {
    var onFocusChange: (Bool) -> Void = { _ in }
    var placeholder = "iMessage" { didSet { needsDisplay = true } }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange(false) }
        return ok
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            let p = LionTheme.palette(for: effectiveAppearance)
            NSAttributedString(string: placeholder, attributes: [
                .font: ComposerFieldView.font, .foregroundColor: p.fieldPlaceholder,
            ]).draw(at: NSPoint(x: textContainerOrigin.x, y: textContainerOrigin.y))
        }
    }
}

struct ComposerFieldRepresentable: NSViewRepresentable {
    let store: AppStore
    @Binding var height: CGFloat

    final class Coordinator: NSObject, NSTextViewDelegate {
        let store: AppStore
        var height: Binding<CGFloat>
        weak var field: ComposerFieldView?
        var cancellables: Set<AnyCancellable> = []

        init(store: AppStore, height: Binding<CGFloat>) {
            self.store = store
            self.height = height
        }

        @MainActor func textDidChange(_ notification: Notification) {
            guard let field else { return }
            if store.draft != field.textView.string { store.draft = field.textView.string }
            updateHeight(animated: true)
        }

        /// Growing to fit another line, or shrinking back after a send, eases over ~0.15 s.
        @MainActor func updateHeight(animated: Bool) {
            guard let field else { return }
            let h = ComposerFieldView.height(forTextHeight: field.textHeight)
            guard abs(h - height.wrappedValue) > 0.5 else { return }
            let animation = animated && !LionMotion.reduceMotion ? LionMotion.easeOut(LionMotion.composerResize) : nil
            withAnimation(animation) { height.wrappedValue = h }
        }

        @MainActor func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                if flags.contains(.shift) || flags.contains(.option) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                if store.presentedError != nil {
                    store.confirmError()
                } else {
                    store.sendDraft()
                }
                return true
            }
            return false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(store: store, height: $height) }

    func makeNSView(context: Context) -> ComposerFieldView {
        let field = ComposerFieldView()
        let coordinator = context.coordinator
        coordinator.field = field
        field.textView.delegate = coordinator
        field.textView.string = store.draft

        store.$draft
            .receive(on: DispatchQueue.main)
            .sink { [weak field, weak coordinator] draft in
                guard let field, field.textView.string != draft else { return }
                field.textView.string = draft
                field.textView.needsDisplay = true
                coordinator?.updateHeight(animated: true)
            }
            .store(in: &coordinator.cancellables)

        store.$selectedConversationID
            .combineLatest(store.$conversations)
            .receive(on: DispatchQueue.main)
            .sink { [weak field] id, list in
                let service = list.first { $0.id == id }?.serviceName ?? "iMessage"
                field?.textView.placeholder = service == "iMessage" ? "iMessage" : "Text Message"
            }
            .store(in: &coordinator.cancellables)

        store.focusComposer
            .receive(on: DispatchQueue.main)
            .sink { [weak field] in
                guard let field else { return }
                field.window?.makeFirstResponder(field.textView)
            }
            .store(in: &coordinator.cancellables)

        DispatchQueue.main.async { coordinator.updateHeight(animated: false) }
        return field
    }

    func updateNSView(_ nsView: ComposerFieldView, context: Context) {
        context.coordinator.height = $height
    }
}
