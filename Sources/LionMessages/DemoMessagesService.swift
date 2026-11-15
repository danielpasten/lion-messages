import Foundation
import MessagesModel
import UniformTypeIdentifiers

/// Believable but entirely invented conversations, for development and screenshots (`--demo`).
final class DemoMessagesService: MessagesService {
    /// `--demo-send-error automation|script` makes `send` fail, to exercise the error sheet.
    var simulatedSendError: SendError?
    /// `--demo-access-after`: report missing Full Disk Access until this is set back to true.
    var hasAccess = true

    private var conversations: [Conversation] = []
    private var messages: [Int64: [Message]] = [:]
    private var nextMessageID: Int64 = 100_000
    private var onChange: (() -> Void)?
    private var nextAttachmentID: Int64 = 9_000
    /// Pictures, files and buddy pictures drawn at launch into a temporary folder.
    private let art = DemoArt.make()

    /// Files for the `--demo` link-preview stub (never fetched from the network).
    var linkPreviewStubArt: (image: URL, icon: URL) { (art.cabinView, art.previewIcon) }
    /// The demo's link-preview cache: a fresh temporary folder per launch (so the stub's fetch
    /// is seen every time), never the real cache. Leftovers from earlier launches are removed.
    lazy var linkPreviewCacheDirectory: URL = {
        let parent = art.directory.appendingPathComponent("LinkPreviews", isDirectory: true)
        let fm = FileManager.default
        for old in (try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let date = (try? old.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(date) > 3600 { try? fm.removeItem(at: old) }
        }
        return parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }()

    init(now: Date = Date()) {
        build(now: now)
    }

    func contactImageData(forHandle handle: String?) async -> Data? {
        // A little latency, like Contacts.
        try? await Task.sleep(nanoseconds: 40_000_000)
        return art.avatars[handle ?? "me"]
    }

    func checkAccess() async -> AccessState { hasAccess ? .granted : .fullDiskAccessDenied }

    func loadConversations() async throws -> [Conversation] {
        conversations.sorted { ($0.lastMessageDate ?? .distantPast) > ($1.lastMessageDate ?? .distantPast) }
    }

    func loadMessages(in conversation: Conversation, limit: Int) async throws -> [Message] {
        Array((messages[conversation.id] ?? []).suffix(limit))
    }

    func requestContactsAccess() async -> Bool { false }

    func startWatching(onChange: @escaping () -> Void) { self.onChange = onChange }
    func stopWatching() { onChange = nil }

    func send(_ text: String, to conversation: Conversation) async throws {
        try await Task.sleep(nanoseconds: 150_000_000)
        if let simulatedSendError { throw simulatedSendError }
        let message = Message(id: nextMessageID, guid: "demo-\(nextMessageID)", text: text, isFromMe: true,
                              date: Date(), senderHandle: nil, senderName: nil,
                              serviceName: conversation.serviceName, hasAttachment: false)
        nextMessageID += 1
        messages[conversation.id, default: []].append(message)
        if let i = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[i].lastMessagePreview = text
            conversations[i].lastMessageDate = message.date
            conversations[i].lastMessageIsFromMe = true
        }
        let handler = onChange
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { handler?() }
    }

    /// Appends one message per file (pointing at the file itself, so it shows inline), then the text.
    func send(attachments: [URL], text: String, to conversation: Conversation) async throws {
        // A little longer than text, so the composer's spinner is visible.
        try await Task.sleep(nanoseconds: 450_000_000)
        if let simulatedSendError { throw simulatedSendError }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var sent: [Message] = []
        for url in attachments {
            let type = UTType(filenameExtension: url.pathExtension)
            let kind: MessageAttachment.Kind = type?.conforms(to: .image) == true ? .image
                : type?.conforms(to: .movie) == true ? .video : type?.conforms(to: .audio) == true ? .audio : .other
            sent.append(Message(id: nextMessageID, guid: "demo-\(nextMessageID)", text: LionConstants.attachmentPlaceholder,
                                isFromMe: true, date: Date(), senderHandle: nil, senderName: nil,
                                serviceName: conversation.serviceName, hasAttachment: true,
                                attachments: [attachment(kind, url, mime: type?.preferredMIMEType, uti: type?.identifier)]))
            nextMessageID += 1
        }
        if !body.isEmpty {
            sent.append(Message(id: nextMessageID, guid: "demo-\(nextMessageID)", text: body, isFromMe: true,
                                date: Date(), senderHandle: nil, senderName: nil,
                                serviceName: conversation.serviceName, hasAttachment: false))
            nextMessageID += 1
        }
        messages[conversation.id, default: []].append(contentsOf: sent)
        if let i = conversations.firstIndex(where: { $0.id == conversation.id }), let last = sent.last {
            conversations[i].lastMessagePreview = last.text
            conversations[i].lastMessageDate = last.date
            conversations[i].lastMessageIsFromMe = true
        }
        let handler = onChange
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { handler?() }
    }

    /// `--demo-incoming-after`: someone writes to each of these conversations (in order), as if
    /// Messages had just received them. One database change notification for all of them.
    func deliverIncoming(to ids: [Int64], withPicture: Bool = false) {
        let texts = ["Just got home — Biscuit knocked a plant off the windowsill 🙈",
                     "Quick question when you have a sec", "Are we still on for this weekend?"]
        for (n, id) in ids.enumerated() {
            guard let i = conversations.firstIndex(where: { $0.id == id }) else { continue }
            let c = conversations[i]
            let sender = c.isGroup ? "Jonah Park" : c.title
            let message = Message(id: nextMessageID, guid: "demo-\(nextMessageID)", text: texts[n % texts.count],
                                  isFromMe: false, date: Date().addingTimeInterval(Double(n)),
                                  senderHandle: c.isGroup ? "jonah.p@example.com" : c.participantHandles.first,
                                  senderName: sender,
                                  serviceName: c.serviceName, hasAttachment: false)
            nextMessageID += 1
            messages[id, default: []].append(message)
            conversations[i].lastMessagePreview = message.text
            conversations[i].lastMessageDate = message.date
            conversations[i].lastMessageIsFromMe = false
            if withPicture && n == 0 {
                // `--demo-incoming-picture`: a photo follows the first text (rich rows animate in too).
                let picture = Message(id: nextMessageID, guid: "demo-\(nextMessageID)", text: LionConstants.attachmentPlaceholder,
                                      isFromMe: false, date: message.date.addingTimeInterval(1),
                                      senderHandle: message.senderHandle, senderName: sender, serviceName: c.serviceName,
                                      hasAttachment: true,
                                      attachments: [attachment(.image, art.porchCat, mime: "image/jpeg")])
                nextMessageID += 1
                messages[id, default: []].append(picture)
                conversations[i].lastMessagePreview = picture.text
                conversations[i].lastMessageDate = picture.date
            }
        }
        onChange?()
    }

    // MARK: - Fake data

    /// A scripted line: who said it (nil = me) and minutes before "now" (or an absolute offset).
    private struct Line {
        var from: String?
        var text: String
        var minutesAgo: Double
        var attachments: [MessageAttachment] = []
        var preview: LinkPreview?
    }

    private func attachment(_ kind: MessageAttachment.Kind, _ url: URL?, name: String? = nil, mime: String? = nil,
                            uti: String? = nil, sticker: Bool = false) -> MessageAttachment {
        nextAttachmentID += 1
        let size = url.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber }
        return MessageAttachment(id: nextAttachmentID, kind: kind, fileURL: url, mimeType: mime, uti: uti,
                                 displayName: name ?? url?.lastPathComponent, byteCount: size?.int64Value,
                                 isSticker: sticker)
    }

    private func build(now: Date) {
        let cal = Calendar.current
        // Minutes ago for "today at hh:mm", clamped so nothing lands in the future.
        func todayAt(_ h: Int, _ m: Int) -> Double {
            let d = cal.date(bySettingHour: h, minute: m, second: 0, of: now) ?? now
            return max(now.timeIntervalSince(d) / 60, 1)
        }
        func daysAgo(_ days: Int, _ h: Int, _ m: Int) -> Double {
            let base = cal.date(byAdding: .day, value: -days, to: now) ?? now
            let d = cal.date(bySettingHour: h, minute: m, second: 0, of: base) ?? base
            return now.timeIntervalSince(d) / 60
        }

        // 1. A long, varied thread (over 300 messages so the 300 limit applies).
        var long: [Line] = [
            Line(from: "Maya", text: "Are you still up for the farmers market Saturday?", minutesAgo: daysAgo(1, 18, 2)),
            Line(from: nil, text: "Yes! What time were you thinking?", minutesAgo: daysAgo(1, 18, 4)),
            Line(from: "Maya", text: "Early-ish. The good peaches are gone by 10 🍑", minutesAgo: daysAgo(1, 18, 5)),
            Line(from: nil, text: "8:30 then. I'll bring the big tote bags", minutesAgo: daysAgo(1, 18, 6)),
            Line(from: "Maya", text: "Perfect", minutesAgo: daysAgo(1, 18, 6)),
            Line(from: "Maya", text: "Oh also — did you ever finish that book I lent you? No pressure, my sister wants to borrow it next and I said I'd ask.", minutesAgo: daysAgo(1, 21, 30)),
            Line(from: nil, text: "Two chapters left. I'll bring it Saturday!", minutesAgo: daysAgo(1, 21, 44)),
            Line(from: nil, text: "Honestly it's the best thing I've read all year — the ending of part two completely wrecked me, and I want to talk about the lighthouse chapter when you have time.", minutesAgo: daysAgo(1, 21, 46)),
            Line(from: "Maya", text: "[Attachment]", minutesAgo: todayAt(8, 12),
                 attachments: [attachment(.image, art.porchCat, mime: "image/jpeg")]),
            Line(from: "Maya", text: "Look what showed up on my porch this morning", minutesAgo: todayAt(8, 12)),
            Line(from: nil, text: "Is that a CAT?", minutesAgo: todayAt(8, 15)),
            Line(from: nil, text: "Are you keeping it??", minutesAgo: todayAt(8, 15)),
            Line(from: "Maya", text: "He's very fluffy and very insistent.\nI've named him Biscuit.\nThis is not a discussion.", minutesAgo: todayAt(8, 17)),
            Line(from: nil, text: "Biscuit 😂 Of course you did", minutesAgo: todayAt(8, 18)),
            Line(from: "Maya", text: "Can you grab some cat food on your way Saturday? The salmon kind. I'll pay you back", minutesAgo: todayAt(9, 38)),
            Line(from: nil, text: "On it 👍", minutesAgo: todayAt(9, 41)),
        ]
        let filler = [
            "Did you see the game last night?", "Haha no, I fell asleep at 9", "Classic",
            "Lunch Thursday?", "Can't, dentist. Friday?", "Friday works", "Running 5 min late, sorry!",
            "No worries, I grabbed us a table by the window",
            "That new place on Elm is really good, we should go back sometime and try the dumplings",
            "Thanks for today ☺️", "Of course! Anytime", "What was the name of that podcast?",
            "The one about the lighthouse keepers? \"Long Watch\" I think", "Got it, thanks!",
            "Happy birthday!! 🎉🎂", "Thank you!!", "Ugh, Mondays", "Coffee?", "Always",
        ]
        var t = daysAgo(19, 10, 0)
        var older: [Line] = []
        for i in 0..<330 {
            older.append(Line(from: i % 3 == 1 ? nil : "Maya", text: filler[i % filler.count], minutesAgo: t))
            t -= (i % 7 == 6) ? 300 : 2 + Double(i % 5) * 3
            t = max(t, daysAgo(2, 9, 0))
        }
        long = older + long

        add(id: 1, title: "Maya Lindqvist", handle: "+14155550123", lines: long)

        // 2. Group chat.
        add(id: 2, title: "Hiking Crew", handle: "chat684213", isGroup: true,
            participants: ["+14155550188", "jonah.p@example.com", "+14155550142"],
            senderHandles: ["Jonah Park": "jonah.p@example.com", "Priya Natarajan": "+14155550188",
                            "Leo Brandt": "+14155550142"], lines: [
                Line(from: "Jonah Park", text: "Trail report: Mount Tam is muddy but gorgeous", minutesAgo: todayAt(7, 50)),
                Line(from: "Jonah Park", text: "Sunday 7am at the trailhead?", minutesAgo: todayAt(7, 51)),
                Line(from: "Priya Natarajan", text: "I'm in. Bringing the good trail mix", minutesAgo: todayAt(8, 3)),
                Line(from: nil, text: "Count me in! Who's driving?", minutesAgo: todayAt(8, 20)),
                Line(from: "Leo Brandt", text: "I can take 4 in the wagon", minutesAgo: todayAt(8, 24)),
                Line(from: "Leo Brandt", text: "Leaving from the bakery parking lot at 6:30", minutesAgo: todayAt(8, 24)),
                Line(from: "Priya Natarajan", text: "🙌", minutesAgo: todayAt(8, 26)),
            ])

        // Rich content: pictures, stickers, files, link previews, things not downloaded.
        let trails = LinkPreview(
            url: URL(string: "https://trails.example.com/lakeside-loop")!,
            title: "Lakeside Loop — an easy 6.2 mile hike with big views of the water",
            summary: "Gentle grades, two footbridges and a picnic meadow halfway around. Best early in the morning before the crowds arrive.",
            siteName: "Example Trails", imageFileURL: art.previewImage, iconFileURL: art.previewIcon)
        let menu = LinkPreview(
            url: URL(string: "https://www.example.org/menu")!,
            title: "The Pine Table — Dinner Menu",
            summary: "Wood-fired trout, wild mushroom risotto and a rotating list of pies.",
            siteName: nil, imageFileURL: nil, iconFileURL: art.menuIcon)
        add(id: 11, title: "Nora Fielding", handle: "+14155550160", lines: [
            Line(from: "Nora", text: "Made it to the cabin!", minutesAgo: todayAt(9, 2)),
            Line(from: "Nora", text: "The view from the porch this morning", minutesAgo: todayAt(9, 2),
                 attachments: [attachment(.image, art.cabinView, mime: "image/heic")]),
            Line(from: nil, text: "Wow. Jealous.", minutesAgo: todayAt(9, 4)),
            Line(from: nil, text: "[Attachment]", minutesAgo: todayAt(9, 4),
                 attachments: [attachment(.image, art.sticker, mime: "image/png", sticker: true)]),
            Line(from: "Nora", text: "[Attachment]", minutesAgo: todayAt(9, 6),
                 attachments: [attachment(.video, nil, name: "IMG_3004.MOV", mime: "video/quicktime")]),
            Line(from: "Nora", text: "[Attachment]", minutesAgo: todayAt(9, 6),
                 attachments: [attachment(.image, nil, name: "IMG_3005.HEIC", mime: "image/heic")]),
            Line(from: "Nora", text: "Sorry, the signal up here is terrible", minutesAgo: todayAt(9, 7)),
            Line(from: "Nora", text: "Sunrise, sped up", minutesAgo: todayAt(9, 8),
                 attachments: art.clip.map { [attachment(.video, $0, mime: "video/quicktime")] } ?? []),
            Line(from: nil, text: "https://trails.example.com/lakeside-loop", minutesAgo: todayAt(9, 9), preview: trails),
            Line(from: nil, text: "We should do this one Saturday", minutesAgo: todayAt(9, 9)),
            Line(from: "Nora", text: "Yes! And dinner here after? https://www.example.org/menu", minutesAgo: todayAt(9, 11),
                 preview: menu),
            Line(from: nil, text: "https://maps.example.net/directions?to=cabin", minutesAgo: todayAt(9, 12)),
            Line(from: "Nora", text: "[Attachment]", minutesAgo: todayAt(9, 13),
                 attachments: [attachment(.other, art.itinerary, mime: "application/pdf", uti: "com.adobe.pdf")]),
            Line(from: "Nora", text: "Also I made you this", minutesAgo: todayAt(9, 14),
                 attachments: [attachment(.image, art.tiny, mime: "image/png")]),
            Line(from: nil, text: "[Attachment]", minutesAgo: todayAt(9, 15),
                 attachments: [attachment(.image, art.animated, mime: "image/gif")]),
            Line(from: "Nora", text: "See you Saturday 👋", minutesAgo: todayAt(9, 16)),
        ])

        add(id: 3, title: "Dad", handle: "+14155550167", lines: [
            Line(from: "Dad", text: "Did you call your grandmother?", minutesAgo: daysAgo(1, 11, 5)),
            Line(from: nil, text: "Yesterday! She says hi", minutesAgo: daysAgo(1, 11, 30)),
            Line(from: "Dad", text: "Good. Also the garage door is making that noise again", minutesAgo: daysAgo(1, 12, 0)),
        ])

        add(id: 4, title: "+1 (415) 555-0199", handle: "+14155550199", service: "SMS", lines: [
            Line(from: "+1 (415) 555-0199", text: "Your package from Juniper Home will arrive tomorrow between 2–6 PM. Reply STOP to opt out.", minutesAgo: daysAgo(1, 15, 12)),
        ])

        add(id: 5, title: "ellie.w@example.com", handle: "ellie.w@example.com", lines: [
            Line(from: "ellie.w@example.com", text: "Here are the photos from the wedding!", minutesAgo: daysAgo(3, 19, 40)),
            Line(from: "ellie.w@example.com", text: "[Attachment]", minutesAgo: daysAgo(3, 19, 40),
                 attachments: [attachment(.image, art.weddingWide, mime: "image/jpeg"),
                               attachment(.image, art.weddingTall, mime: "image/jpeg")]),
            Line(from: nil, text: "These are beautiful, thank you so much", minutesAgo: daysAgo(3, 20, 15)),
        ])

        add(id: 6, title: "Theo Okafor", handle: "+14155550111", lines: [
            Line(from: nil, text: "Did the band ever pick a name?", minutesAgo: daysAgo(4, 22, 0)),
            Line(from: "Theo Okafor", text: "We're between \"Quiet Machines\" and \"The Overdue Library Books\"", minutesAgo: daysAgo(4, 22, 9)),
            Line(from: nil, text: "Second one, obviously", minutesAgo: daysAgo(4, 22, 10)),
        ])

        add(id: 7, title: "Rosa Delgado", handle: "+14155550175", lines: [
            Line(from: "Rosa Delgado", text: "Recipe for the lemon cake:\n– 2 cups flour\n– 1 cup sugar\n– zest of 3 lemons\n– lots of butter", minutesAgo: daysAgo(6, 14, 0)),
            Line(from: nil, text: "You're the best", minutesAgo: daysAgo(6, 14, 30)),
        ])

        add(id: 8, title: "Sam Whitaker", handle: "sam.whitaker@example.com", lines: [
            Line(from: "Sam Whitaker", text: "Can you send me the slides from Tuesday?", minutesAgo: daysAgo(12, 10, 0)),
            Line(from: nil, text: "Sent! Check your email", minutesAgo: daysAgo(12, 10, 20)),
            Line(from: "Sam Whitaker", text: "Thanks! Here are the whiteboard photos from the offsite",
                 minutesAgo: daysAgo(12, 10, 31),
                 attachments: art.slides.map { attachment(.image, $0, mime: "image/png") }),
        ])

        add(id: 9, title: "Book Club", handle: "chat993107", isGroup: true,
            participants: ["+14155550131", "+14155550152"], lines: [
                Line(from: "Hannah Cole", text: "Next pick: \"The Remains of the Day\"?", minutesAgo: daysAgo(24, 20, 0)),
                Line(from: "Marcus Bell", text: "Seconded", minutesAgo: daysAgo(24, 20, 5)),
                Line(from: nil, text: "Love it. See you all on the 3rd", minutesAgo: daysAgo(24, 20, 30)),
            ])

        add(id: 10, title: "Aunt June", handle: "+14155550104", lines: [
            Line(from: "Aunt June", text: "Merry Christmas sweetheart! ❤️", minutesAgo: daysAgo(320, 9, 0)),
            Line(from: nil, text: "Merry Christmas! Miss you!", minutesAgo: daysAgo(320, 9, 30)),
        ])
    }

    private func add(id: Int64, title: String, handle: String, service: String = "iMessage",
                     isGroup: Bool = false, participants: [String]? = nil,
                     senderHandles: [String: String] = [:], lines: [Line]) {
        let now = Date()
        var list: [Message] = []
        for line in lines {
            let isAttachment = line.text == LionConstants.attachmentPlaceholder || !line.attachments.isEmpty
            list.append(Message(
                id: nextMessageID, guid: "demo-\(nextMessageID)", text: line.text,
                isFromMe: line.from == nil, date: now.addingTimeInterval(-line.minutesAgo * 60),
                senderHandle: line.from.map { senderHandles[$0] ?? handle },
                senderName: line.from, serviceName: service, hasAttachment: isAttachment,
                attachments: line.attachments, linkPreview: line.preview))
            nextMessageID += 1
        }
        // Stable chronological order (several scripted lines share a minute).
        list = list.enumerated().sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }.map(\.element)
        messages[id] = list
        let last = list.last
        conversations.append(Conversation(
            id: id, guid: "\(service);\(isGroup ? "+" : "-");\(handle)", chatIdentifier: handle,
            serviceName: service, isGroup: isGroup, participantHandles: participants ?? [handle],
            title: title, lastMessagePreview: last?.text ?? "", lastMessageDate: last?.date,
            lastMessageIsFromMe: last?.isFromMe ?? false))
    }
}
