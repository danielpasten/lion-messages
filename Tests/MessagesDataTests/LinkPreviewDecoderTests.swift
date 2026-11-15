import Foundation
import XCTest
@testable import MessagesData

// Stand-ins archived under the real class names Messages uses, so the test archive mirrors the
// real payload_data structure: RichLink -> LPLinkMetadata -> NSURL / RichLinkImageAttachmentSubstitute.

final class FakeRichLink: NSObject, NSCoding {
    let metadata: NSObject?
    let isPlaceholder: Bool
    init(metadata: NSObject?, isPlaceholder: Bool = false) { self.metadata = metadata; self.isPlaceholder = isPlaceholder }
    func encode(with coder: NSCoder) {
        coder.encode(isPlaceholder, forKey: "richLinkIsPlaceholder")
        coder.encode(metadata, forKey: "richLinkMetadata")
    }
    init?(coder: NSCoder) { nil }
}

final class FakeLinkMetadata: NSObject, NSCoding {
    var originalURL: NSURL?
    var url: NSURL?
    var title: String?
    var summary: String?
    var siteName: String?
    var image: FakeImageSubstitute?
    var icon: FakeImageSubstitute?
    override init() {}
    func encode(with coder: NSCoder) {
        if let originalURL { coder.encode(originalURL, forKey: "originalURL") }
        if let url { coder.encode(url, forKey: "URL") }
        if let title { coder.encode(title, forKey: "title") }
        if let summary { coder.encode(summary, forKey: "summary") }
        if let siteName { coder.encode(siteName, forKey: "siteName") }
        if let image { coder.encode(image, forKey: "image") }
        if let icon { coder.encode(icon, forKey: "icon") }
        coder.encode(1, forKey: "version")
        coder.encode(false, forKey: "usesActivityPub")
        coder.encode("summary_large_image", forKey: "twitterCard")
    }
    init?(coder: NSCoder) { nil }
}

final class FakeImageSubstitute: NSObject, NSCoding {
    let index: Int
    let mime: String
    init(index: Int, mime: String = "image/png") { self.index = index; self.mime = mime }
    func encode(with coder: NSCoder) {
        coder.encode(mime, forKey: "MIMEType")
        coder.encode(index, forKey: "richLinkImageAttachmentSubstituteIndex")
        coder.encode(0, forKey: "imageType")
        coder.encode(0.5, forKey: "dominantColor.red")
    }
    init?(coder: NSCoder) { nil }
}

/// A keyed archive shaped like a real URL balloon payload_data.
func richLinkPayload(_ metadata: FakeLinkMetadata?) -> Data {
    let archiver = NSKeyedArchiver(requiringSecureCoding: false)
    archiver.setClassName("RichLink", for: FakeRichLink.self)
    archiver.setClassName("LPLinkMetadata", for: FakeLinkMetadata.self)
    archiver.setClassName("RichLinkImageAttachmentSubstitute", for: FakeImageSubstitute.self)
    archiver.encode(FakeRichLink(metadata: metadata), forKey: NSKeyedArchiveRootObjectKey)
    archiver.finishEncoding()
    return archiver.encodedData
}

func sampleMetadata(imageIndex: Int? = 1, iconIndex: Int? = 0) -> FakeLinkMetadata {
    let m = FakeLinkMetadata()
    m.originalURL = NSURL(string: "https://example.com/story?id=1")
    m.url = NSURL(string: "https://www.example.com/story")
    m.title = "  Example Story  "
    m.summary = "A synthetic summary."
    m.siteName = "Example"
    m.image = imageIndex.map { FakeImageSubstitute(index: $0, mime: "image/jpeg") }
    m.icon = iconIndex.map { FakeImageSubstitute(index: $0) }
    return m
}

final class LinkPreviewDecoderTests: XCTestCase {
    func testDecodesRealShapedArchive() throws {
        let data = richLinkPayload(sampleMetadata())
        XCTAssertTrue(data.starts(with: Data("bplist00".utf8)))
        let decoded = try XCTUnwrap(LinkPreviewDecoder.decode(data))
        XCTAssertEqual(decoded.url, URL(string: "https://example.com/story?id=1"))
        XCTAssertEqual(decoded.title, "Example Story")
        XCTAssertEqual(decoded.summary, "A synthetic summary.")
        XCTAssertEqual(decoded.siteName, "Example")
        XCTAssertEqual(decoded.imageAttachmentIndex, 1)
        XCTAssertEqual(decoded.iconAttachmentIndex, 0)
    }

    func testFallsBackToURLWhenOriginalURLMissing() throws {
        let m = sampleMetadata(imageIndex: nil, iconIndex: nil)
        m.originalURL = nil
        m.title = nil
        m.summary = "   "
        let decoded = try XCTUnwrap(LinkPreviewDecoder.decode(richLinkPayload(m)))
        XCTAssertEqual(decoded.url, URL(string: "https://www.example.com/story"))
        XCTAssertNil(decoded.title)
        XCTAssertNil(decoded.summary)
        XCTAssertNil(decoded.imageAttachmentIndex)
        XCTAssertNil(decoded.iconAttachmentIndex)
    }

    func testRelativeURLWithBase() throws {
        let m = FakeLinkMetadata()
        m.originalURL = NSURL(string: "page/two?x=1", relativeTo: URL(string: "https://example.org/dir/"))
        let decoded = try XCTUnwrap(LinkPreviewDecoder.decode(richLinkPayload(m)))
        XCTAssertEqual(decoded.url.absoluteString, "https://example.org/dir/page/two?x=1")
    }

    func testNullMetadataOrNoURLReturnsNil() {
        XCTAssertNil(LinkPreviewDecoder.decode(richLinkPayload(nil)))
        let m = FakeLinkMetadata()
        m.title = "Title only"
        XCTAssertNil(LinkPreviewDecoder.decode(richLinkPayload(m)))
    }

    func testGarbageAndTruncatedInputReturnNil() throws {
        XCTAssertNil(LinkPreviewDecoder.decode(Data()))
        XCTAssertNil(LinkPreviewDecoder.decode(Data("bplist00".utf8)))
        XCTAssertNil(LinkPreviewDecoder.decode(Data(repeating: 0xAB, count: 512)))
        let good = richLinkPayload(sampleMetadata())
        for cut in [9, 16, good.count / 3, good.count / 2, good.count - 1] {
            XCTAssertNil(LinkPreviewDecoder.decode(good.prefix(cut)), "cut \(cut)")
        }
        var flipped = good
        for i in stride(from: 8, to: flipped.count, by: 7) { flipped[i] ^= 0x5A }
        _ = LinkPreviewDecoder.decode(flipped) // must not crash
        // Valid plists that are not keyed archives.
        let plainBinary = try PropertyListSerialization.data(fromPropertyList: ["a": 1], format: .binary, options: 0)
        XCTAssertNil(LinkPreviewDecoder.decode(plainBinary))
        let arrayRoot = try PropertyListSerialization.data(fromPropertyList: [1, 2], format: .binary, options: 0)
        XCTAssertNil(LinkPreviewDecoder.decode(arrayRoot))
        let xml = try PropertyListSerialization.propertyList(from: good, format: nil)
        let xmlData = try PropertyListSerialization.data(fromPropertyList: xml, format: .xml, options: 0)
        XCTAssertNil(LinkPreviewDecoder.decode(xmlData)) // only binary payloads are expected
        // Some other archived root object.
        let other = try NSKeyedArchiver.archivedData(withRootObject: ["k": "v"], requiringSecureCoding: false)
        XCTAssertNil(LinkPreviewDecoder.decode(other))
    }

    func testKeyedArchiveUIDDetection() throws {
        let data = richLinkPayload(sampleMetadata())
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let top = try XCTUnwrap(plist["$top"] as? [String: Any])
        XCTAssertNotNil(KeyedArchiveUID.value(of: try XCTUnwrap(top["root"])))
        XCTAssertNil(KeyedArchiveUID.value(of: "CFKeyedArchiverUID value = 3"))
        XCTAssertNil(KeyedArchiveUID.value(of: NSNumber(value: 3)))
    }
}
