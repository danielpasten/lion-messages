import AppKit
import Combine
import SwiftUI

/// The unified Lion title bar + toolbar, drawn by hand (the real traffic lights sit on top of it).
final class LionToolbarView: LionView {
    static let height: CGFloat = 56
    /// Height of the title line (where the traffic lights live); the controls row sits below it.
    static let titleRowHeight: CGFloat = 26

    var title = "Lion Messages" {
        didSet { if title != oldValue { needsDisplay = true; window?.title = title } }
    }

    let searchField = LionSearchField()
    private let sidebarButton: LionTexturedButton
    private let refreshButton: LionTexturedButton
    private let composeButton: LionTexturedButton
    let audioCallButton: LionTexturedButton
    let videoCallButton: LionTexturedButton

    /// A popped-out conversation's toolbar: just the title and the call buttons.
    private let compact: Bool

    init(compact: Bool = false, onToggleSidebar: @escaping () -> Void, onRefresh: @escaping () -> Void, onCompose: @escaping () -> Void,
         onAudioCall: @escaping () -> Void, onVideoCall: @escaping () -> Void) {
        sidebarButton = LionTexturedButton(glyph: .sidebar, toolTip: "Show or Hide Conversations", action: onToggleSidebar)
        refreshButton = LionTexturedButton(glyph: .refresh, toolTip: "Refresh", action: onRefresh)
        composeButton = LionTexturedButton(glyph: .compose, toolTip: "Write a Message", action: onCompose)
        audioCallButton = LionTexturedButton(glyph: .phone, toolTip: "FaceTime Audio", action: onAudioCall)
        videoCallButton = LionTexturedButton(glyph: .video, toolTip: "FaceTime Video", action: onVideoCall)
        self.compact = compact
        super.init(frame: .zero)
        if !compact {
            addSubview(sidebarButton)
            addSubview(refreshButton)
            addSubview(composeButton)
        }
        addSubview(audioCallButton)
        addSubview(videoCallButton)
        if !compact { addSubview(searchField) }
    }

    /// Calls need a 1:1 conversation; the tooltip says why the buttons are dimmed otherwise.
    func setCallsEnabled(_ enabled: Bool, isGroup: Bool) {
        for (button, name) in [(audioCallButton, "FaceTime Audio"), (videoCallButton, "FaceTime Video")] {
            button.isEnabled = enabled
            button.toolTip = enabled || !isGroup ? name : "\(name) works with one person at a time"
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var mouseDownCanMoveWindow: Bool { true }

    override func layout() {
        super.layout()
        let rowMid = Self.titleRowHeight + (bounds.height - Self.titleRowHeight) / 2 - 1
        // Buttons line up with the sidebar like Mail's toolbar did.
        sidebarButton.frame = NSRect(x: 14, y: rowMid - 11.5, width: 34, height: 23)
        refreshButton.frame = NSRect(x: 54, y: rowMid - 11.5, width: 34, height: 23)
        composeButton.frame = NSRect(x: 94, y: rowMid - 11.5, width: 34, height: 23)
        if compact {
            videoCallButton.frame = NSRect(x: bounds.width - 14 - 34, y: rowMid - 11.5, width: 34, height: 23)
            audioCallButton.frame = NSRect(x: bounds.width - 14 - 34 - 6 - 34, y: rowMid - 11.5, width: 34, height: 23)
            return
        }
        let searchWidth: CGFloat = min(206, max(120, bounds.width * 0.24))
        let halo = LionSearchField.halo
        searchField.frame = NSRect(x: bounds.width - searchWidth - 9 - halo, y: rowMid - 14 - halo,
                                   width: searchWidth + 2 * halo, height: 28 + 2 * halo)
        // Audio and video sit together left of the search field, like iChat's call buttons.
        let callsRight = bounds.width - searchWidth - 9 - 12
        videoCallButton.frame = NSRect(x: callsRight - 34, y: rowMid - 11.5, width: 34, height: 23)
        audioCallButton.frame = NSRect(x: callsRight - 34 - 6 - 34, y: rowMid - 11.5, width: 34, height: 23)
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = palette
        let active = activeFraction
        // Crossfade between the inactive and active gradients.
        if active < 1 { p.toolbarInactive.drawVertical(in: bounds, flipped: true) }
        if active > 0, let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.setAlpha(active)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            p.toolbarActive.drawVertical(in: bounds, flipped: true)
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }

        p.toolbarTopHighlight.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        p.toolbarBottomLine.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: LionFont.regular(13),
            .foregroundColor: p.titleTextInactive.lionMix(p.titleText, active),
            .shadow: p.etchShadow.nsShadow,
        ]
        let str = NSAttributedString(string: title, attributes: attrs)
        let size = str.size()
        // Keep clear of the traffic lights (≈ 80 pt) on narrow windows.
        let maxWidth = bounds.width - 2 * 90
        let width = min(size.width, maxWidth)
        let rect = NSRect(x: (bounds.width - width) / 2, y: (Self.titleRowHeight - size.height) / 2 + 1,
                          width: width, height: size.height)
        str.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            // Honor System Settings > Desktop & Dock > "Double-click a window's title bar to…".
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
            switch action {
            case "Minimize": window.performMiniaturize(nil)
            case "None": break
            default: window.performZoom(nil)
            }
            return
        }
        window.performDrag(with: event)
    }
}

/// SwiftUI wrapper; binds the title and search text to the store.
struct ToolbarRepresentable: NSViewRepresentable {
    let store: AppStore

    final class Coordinator {
        var cancellables: Set<AnyCancellable> = []
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LionToolbarView {
        let view = LionToolbarView(
            compact: store.isPopOut,
            onToggleSidebar: { [weak store] in store?.toggleSidebar() },
            onRefresh: { [weak store] in store?.refresh() },
            onCompose: { [weak store] in store?.focusComposer.send() },
            onAudioCall: { [weak store] in store?.requestCall(.audio) },
            onVideoCall: { [weak store] in store?.requestCall(.video) })
        view.searchField.onChange = { [weak store] text in
            if store?.searchText != text { store?.searchText = text }
        }
        store.$searchText
            .receive(on: DispatchQueue.main)
            .sink { [weak view] text in
                guard let field = view?.searchField, field.textField.stringValue != text else { return }
                field.setText(text)
            }
            .store(in: &context.coordinator.cancellables)
        store.$selectedConversationID
            .combineLatest(store.$conversations)
            .receive(on: DispatchQueue.main)
            .sink { [weak view] id, conversations in
                // @Published emits before the property changes: use the emitted values.
                view?.title = conversations.first { $0.id == id }?.title ?? "Lion Messages"
            }
            .store(in: &context.coordinator.cancellables)
        // Re-check after any change that affects calling (selection, access, sheets).
        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak view, weak store] in
                guard let store else { return }
                view?.setCallsEnabled(store.canCall, isGroup: store.selectedConversation?.isGroup ?? false)
            }
            .store(in: &context.coordinator.cancellables)
        view.setCallsEnabled(store.canCall, isGroup: store.selectedConversation?.isGroup ?? false)
        return view
    }

    func updateNSView(_ nsView: LionToolbarView, context: Context) {}
}
