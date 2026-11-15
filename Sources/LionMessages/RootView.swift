import MessagesModel
import SwiftUI

/// Window content: hand-drawn toolbar on top, then either the conversation UI or the access screen.
struct RootView: View {
    @ObservedObject var store: AppStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            ToolbarRepresentable(store: store)
                .frame(height: LionToolbarView.height)
            content
                // A Lion sheet unrolls from under the toolbar's bottom edge over slightly dimmed content.
                .overlay {
                    if store.presentedError != nil || store.pendingCall != nil {
                        Color.black.opacity(LionMotion.sheetDim)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .overlay(alignment: .top) { errorSheet }
                .overlay(alignment: .top) { callSheet }
                .clipped()
                .animation(LionMotion.easeOut(LionMotion.sheet), value: store.presentedError?.id)
                .animation(LionMotion.easeOut(LionMotion.sheet), value: store.pendingCall?.id)
        }
        .font(LionFont.swiftUI(12))
        .ignoresSafeArea()
    }

    /// Permission screen ⇄ conversations crossfade when access is granted (or lost).
    @ViewBuilder private var content: some View {
        ZStack {
            switch store.accessState {
            case .granted:
                conversationUI
                    .transition(.opacity)
            case .some(let state):
                PermissionView(state: state, onCheckAgain: { store.checkAgain() })
                    .transition(.opacity)
            case .none:
                ZStack {
                    LinenBackground()
                    EtchedText(text: "Opening Messages…", size: 15)
                }
                .transition(.opacity)
            }
        }
        .animation(LionMotion.easeInOut(LionMotion.screenCrossfade), value: store.accessState)
    }

    private var conversationUI: some View {
        let p = LionTheme.palette(for: scheme)
        return HStack(spacing: 0) {
            VStack(spacing: 0) {
                SidebarScopeBarRepresentable(store: store)
                    .frame(height: SidebarScopeBar.height)
                SidebarRepresentable(store: store)
                    .overlay {
                        if store.filteredConversations.isEmpty && store.pinnedConversations.isEmpty {
                            EtchedText(text: emptySidebarText, size: 14)
                        }
                    }
            }
            .frame(width: SidebarController.width - 1)
            Rectangle()
                .fill(Color(nsColor: p.sidebarDivider))
                .frame(width: 1)
            VStack(spacing: 0) {
                TranscriptRepresentable(store: store)
                    .overlay {
                        if store.selectedConversationID == nil {
                            EtchedText(text: "No Conversation Selected")
                        }
                    }
                    // Files dragged over the conversation (transcript or composer) light it up.
                    .overlay {
                        if store.isDropTargeted {
                            DropHighlight().transition(.opacity)
                        }
                    }
                    .animation(LionMotion.easeOut(LionMotion.dropHighlight), value: store.isDropTargeted)
                ComposerView(store: store)
            }
        }
    }

    private var emptySidebarText: String {
        if !store.searchText.isEmpty { return "No Results" }
        switch store.scope {
        case .known: return "No Conversations"
        case .unknown: return "No Unknown Senders"
        case .spam: return "No Spam"
        }
    }

    @ViewBuilder private var callSheet: some View {
        if let call = store.pendingCall {
            CallSheet(call: call,
                      picture: store.buddyPicture(isFromMe: false, handle: call.conversation.participantHandles.first),
                      onCall: { store.confirmCall() }, onCancel: { store.cancelCall() })
                .transition(LionMotion.reduceMotion ? .opacity : .move(edge: .top))
                .zIndex(1)
        }
    }

    @ViewBuilder private var errorSheet: some View {
        if let presented = store.presentedError {
            SendErrorSheet(error: presented.error, onDismiss: { store.dismissError() })
                .transition(LionMotion.reduceMotion ? .opacity : .move(edge: .top))
                .zIndex(1)
        }
    }
}
