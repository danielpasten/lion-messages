import AppKit
import MessagesModel

/// Command-line flags (used for development and visual verification).
struct LaunchOptions {
    var demo = false
    /// "light" / "dark"; nil follows the system.
    var appearance: String?
    var forcePermissionScreen = false
    var snapshotPath: String?
    var selectIndex = 0
    var draft: String?
    var size: NSSize?
    var demoSendError: SendError?
    var presentError: SendError?
    /// Snapshot the window in its inactive (not key) state.
    var inactive = false
    /// Send the `--draft` text and `--attach` files right after launch (exercises the send path in demo mode).
    var sendDraft = false
    /// `--attach <path>` (repeatable): pending attachments added at launch.
    var attachPaths: [String] = []
    /// `--show-drop-highlight`: show the drag-and-drop highlight (to check its look).
    var showDropHighlight = false
    var search: String?
    /// `--snapshot-sequence <dir> --frames N --interval ms`: capture N window frames, spaced by
    /// `interval`, starting the moment a trigger fires (send, error, incoming, access, focus, resize…).
    var sequenceDir: String?
    /// Only start the sequence at this trigger (send, error, incoming, access, focus, scroll,
    /// resize, inactive, linkpreview); nil = the first one that fires.
    var sequenceOn: String?
    var frames = 12
    var intervalMs = 33.0
    /// Demo: deliver incoming messages (selected conversation + a lower one) after this many seconds.
    var demoIncomingAfter: Double?
    /// `--demo-incoming-picture`: the delivery to the open conversation includes a photo.
    var demoIncomingPicture = false
    /// Demo: start without access and grant it after this many seconds.
    var demoAccessAfter: Double?
    /// Focus "composer" or "search" shortly after launch.
    var focus: String?
    /// Resize the live window after launch (`--resize-to WxH --resize-after s`).
    var resizeTo: NSSize?
    var resizeAfter = 1.0
    /// Animate the resize like a live drag (several steps) instead of one jump.
    var resizeSteps = 1
    /// Scroll the transcript up by this many points after launch (exercises the overlay scrollers).
    var scrollTranscript: Double?
    var reduceMotion = false
    var slowMotion = 1.0
    /// `--buddy-pictures on|off`: overrides the saved View ▸ Show Buddy Pictures setting for this
    /// launch only (not persisted).
    var buddyPictures: Bool?
    /// `--fetch-link-previews on|off`: overrides View ▸ Fetch Missing Link Previews for this launch
    /// only (not persisted).
    var fetchLinkPreviews: Bool?
    /// `--open-media N`: show the Nth picture or video (0-based, oldest first) of the selected
    /// conversation in Quick Look, `--open-media-after` seconds after launch (default 1).
    var openMedia: Int?
    var openMediaAfter = 1.0
    /// `--toggle-sidebar`: press the toolbar's conversation list button shortly after launch.
    var toggleSidebar = false
    /// `--toggle-buddy-pictures-after s`: flip the setting once, live (not persisted), to test it.
    var toggleBuddyPicturesAfter: Double?
    /// `--scope known|unknown|spam`: the sender list to start on.
    var scope: SidebarScope = .known
    /// `--filter-unknown on|off`: overrides View ▸ Filter Unknown Senders for this launch only.
    var filterUnknown: Bool?
    /// `--call audio|video`: open the call sheet for the selected conversation after launch.
    var call: PendingCall.Kind?

    static func parse(_ args: [String]) -> LaunchOptions {
        var o = LaunchOptions()
        var i = 1
        func value() -> String? {
            i += 1
            return i < args.count ? args[i] : nil
        }
        func sendError(_ s: String?) -> SendError? {
            switch s {
            case "automation": return .automationDenied
            case "script": return .scriptFailed("Messages got an error: Can’t send to this buddy. (-1700)")
            default: return nil
            }
        }
        func size(_ s: String?) -> NSSize? {
            let parts = (s ?? "").lowercased().split(separator: "x").compactMap { Double($0) }
            return parts.count == 2 ? NSSize(width: parts[0], height: parts[1]) : nil
        }
        while i < args.count {
            switch args[i] {
            case "--demo": o.demo = true
            case "--appearance": o.appearance = value()
            case "--force-permission-screen": o.forcePermissionScreen = true
            case "--snapshot": o.snapshotPath = value()
            case "--select": o.selectIndex = value().flatMap(Int.init) ?? 0
            case "--draft": o.draft = value()
            case "--size": o.size = size(value())
            case "--demo-send-error": o.demoSendError = sendError(value())
            case "--present-error": o.presentError = sendError(value())
            case "--inactive": o.inactive = true
            case "--send-draft": o.sendDraft = true
            case "--attach": if let path = value() { o.attachPaths.append(path) }
            case "--show-drop-highlight": o.showDropHighlight = true
            case "--search": o.search = value()
            case "--snapshot-sequence": o.sequenceDir = value()
            case "--sequence-on": o.sequenceOn = value()
            case "--frames": o.frames = value().flatMap(Int.init) ?? o.frames
            case "--interval": o.intervalMs = value().flatMap(Double.init) ?? o.intervalMs
            case "--demo-incoming-after": o.demoIncomingAfter = value().flatMap(Double.init)
            case "--demo-incoming-picture": o.demoIncomingPicture = true
            case "--demo-access-after": o.demoAccessAfter = value().flatMap(Double.init)
            case "--focus": o.focus = value()
            case "--resize-to": o.resizeTo = size(value())
            case "--resize-after": o.resizeAfter = value().flatMap(Double.init) ?? o.resizeAfter
            case "--resize-steps": o.resizeSteps = max(1, value().flatMap(Int.init) ?? 1)
            case "--scroll-transcript": o.scrollTranscript = value().flatMap(Double.init)
            case "--reduce-motion": o.reduceMotion = true
            case "--slow-motion": o.slowMotion = max(1, value().flatMap(Double.init) ?? 1)
            case "--buddy-pictures":
                switch value()?.lowercased() {
                case "on", "true", "1", "yes": o.buddyPictures = true
                case "off", "false", "0", "no": o.buddyPictures = false
                default: break
                }
            case "--fetch-link-previews":
                switch value()?.lowercased() {
                case "on", "true", "1", "yes": o.fetchLinkPreviews = true
                case "off", "false", "0", "no": o.fetchLinkPreviews = false
                default: break
                }
            case "--scope": o.scope = value().flatMap(SidebarScope.init(rawValue:)) ?? .known
            case "--filter-unknown":
                switch value()?.lowercased() {
                case "on", "true", "1", "yes": o.filterUnknown = true
                case "off", "false", "0", "no": o.filterUnknown = false
                default: break
                }
            case "--call":
                switch value()?.lowercased() {
                case "audio": o.call = .audio
                case "video": o.call = .video
                default: break
                }
            case "--open-media": o.openMedia = value().flatMap(Int.init)
            case "--open-media-after": o.openMediaAfter = value().flatMap(Double.init) ?? o.openMediaAfter
            case "--toggle-sidebar": o.toggleSidebar = true
            case "--toggle-buddy-pictures-after": o.toggleBuddyPicturesAfter = value().flatMap(Double.init)
            default: break // Ignore unknown flags (e.g. -NSDocumentRevisionsDebugMode from Xcode).
            }
            i += 1
        }
        return o
    }
}
