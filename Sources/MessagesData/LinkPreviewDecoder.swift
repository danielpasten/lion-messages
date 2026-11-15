import CoreFoundation
import Foundation

/// Decodes `message.payload_data` of URL balloons (`com.apple.messages.URLBalloonProvider`).
///
/// The payload is an NSKeyedArchiver binary plist. Observed structure:
///
///     $top.root -> RichLink { richLinkIsPlaceholder, richLinkMetadata }
///     richLinkMetadata -> LPLinkMetadata { originalURL, URL, title, summary, siteName,
///                                          image, icon, imageMetadata, iconMetadata, ... }
///                          ($null when Messages stored no metadata)
///     originalURL / URL -> NSURL { NS.base ($null or NSURL), NS.relative (String) }
///     image / icon -> RichLinkImageAttachmentSubstitute { richLinkImageAttachmentSubstituteIndex,
///                                                        MIMEType, ... }
///
/// `richLinkImageAttachmentSubstituteIndex` indexes the message's attachments in
/// message_attachment_join order (all hidden `*.pluginPayloadAttachment` files).
///
/// The archive is walked generically through `PropertyListSerialization` (no NSKeyedUnarchiver,
/// so no private classes and no Objective-C exceptions). Returns nil on anything unexpected.
enum LinkPreviewDecoder {
    static let urlBalloonBundleID = "com.apple.messages.URLBalloonProvider"

    struct Decoded: Equatable {
        var url: URL
        var title: String?
        var summary: String?
        var siteName: String?
        /// Index into the message's attachments (join order) of the preview image.
        var imageAttachmentIndex: Int?
        var iconAttachmentIndex: Int?
    }

    static func decode(_ data: Data) -> Decoded? {
        guard data.count > 8, data.prefix(8) == Data("bplist00".utf8) else { return nil }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let archive = plist as? [String: Any],
              (archive["$archiver"] as? String) == "NSKeyedArchiver",
              let objects = archive["$objects"] as? [Any] else { return nil }
        let graph = Graph(objects: objects)

        // Locate LPLinkMetadata: normally root.richLinkMetadata; tolerate the root itself being
        // the metadata, and fall back to the first LPLinkMetadata-classed object.
        var metadata: [String: Any]?
        if let top = archive["$top"] as? [String: Any], let root = graph.dict(top["root"]) {
            if let inner = graph.dict(root["richLinkMetadata"]) {
                metadata = inner
            } else if root["richLinkMetadata"] == nil, graph.className(of: root) == "LPLinkMetadata" {
                metadata = root
            }
        }
        if metadata == nil {
            metadata = objects.lazy.compactMap { $0 as? [String: Any] }
                .first { graph.className(of: $0) == "LPLinkMetadata" }
        }
        guard let meta = metadata else { return nil }

        guard let url = graph.url(meta["originalURL"]) ?? graph.url(meta["URL"]) else { return nil }
        return Decoded(
            url: url,
            title: graph.string(meta["title"]),
            summary: graph.string(meta["summary"]),
            siteName: graph.string(meta["siteName"]),
            imageAttachmentIndex: graph.substituteIndex(meta["image"]),
            iconAttachmentIndex: graph.substituteIndex(meta["icon"]))
    }

    // MARK: - Keyed-archive graph

    private struct Graph {
        let objects: [Any]

        /// Resolves a `CF$UID` reference (or returns non-reference values unchanged).
        func resolve(_ value: Any?) -> Any? {
            guard let value else { return nil }
            guard let index = KeyedArchiveUID.value(of: value) else { return value }
            guard index > 0, index < objects.count else { return nil } // 0 is "$null"
            return objects[index]
        }

        func dict(_ value: Any?) -> [String: Any]? { resolve(value) as? [String: Any] }

        func className(of dict: [String: Any]) -> String? {
            (self.dict(dict["$class"]))?["$classname"] as? String
        }

        func string(_ value: Any?) -> String? {
            let resolved = resolve(value)
            let raw: String?
            if let s = resolved as? String {
                raw = s
            } else if let d = resolved as? [String: Any], let inner = d["NS.string"] {
                raw = resolve(inner) as? String  // NSMutableString-style object
            } else {
                raw = nil
            }
            guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
                  trimmed != "$null" else { return nil }
            return trimmed
        }

        func url(_ value: Any?, depth: Int = 0) -> URL? {
            guard depth < 4 else { return nil }
            let resolved = resolve(value)
            if let s = resolved as? String { return Self.makeURL(s, base: nil) }
            guard let d = resolved as? [String: Any], let relative = string(d["NS.relative"]) else { return nil }
            let base = d["NS.base"].flatMap { url($0, depth: depth + 1) }
            return Self.makeURL(relative, base: base)
        }

        func substituteIndex(_ value: Any?) -> Int? {
            guard let d = dict(value),
                  let n = resolve(d["richLinkImageAttachmentSubstituteIndex"]) as? NSNumber else { return nil }
            let i = n.intValue
            return i >= 0 ? i : nil
        }

        private static func makeURL(_ string: String, base: URL?) -> URL? {
            let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { return nil }
            let url = URL(string: s, relativeTo: base)
                ?? s.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed.union(["#", "%"]))
                    .flatMap { URL(string: $0, relativeTo: base) }
            guard let absolute = url?.absoluteURL, absolute.scheme != nil else { return nil }
            return absolute
        }
    }
}

/// Recognizes `CFKeyedArchiverUID` values returned by `PropertyListSerialization` for `CF$UID`
/// entries. There is no public API, so the type is identified by comparing its CFTypeID with a
/// UID taken from a reference archive, and the integer is read from its description
/// (`<CFKeyedArchiverUID 0x…>{value = N}`).
enum KeyedArchiveUID {
    private static let typeID: CFTypeID? = {
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.encode("x" as NSString, forKey: "k")
        archiver.finishEncoding()
        guard let plist = try? PropertyListSerialization.propertyList(from: archiver.encodedData, format: nil),
              let top = (plist as? [String: Any])?["$top"] as? [String: Any],
              let uid = top["k"] else { return nil }
        return CFGetTypeID(uid as CFTypeRef)
    }()

    static func value(of object: Any) -> Int? {
        // Fast reject for plain plist types.
        if object is String || object is NSNumber || object is Data || object is [Any] || object is [String: Any] || object is Date {
            return nil
        }
        if let typeID {
            guard CFGetTypeID(object as CFTypeRef) == typeID else { return nil }
        }
        let description = String(describing: object)
        guard description.contains("CFKeyedArchiverUID"),
              let range = description.range(of: "value = ") else { return nil }
        let digits = description[range.upperBound...].prefix { $0.isASCII && $0.isNumber }
        return Int(digits)
    }
}
