import Foundation
import XCTest
@testable import MessagesData

final class AttributedBodyDecoderTests: XCTestCase {
    private func roundTrip(_ object: NSObject, expect: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try XCTUnwrap(typedstream(object), "NSArchiver unavailable", file: file, line: line)
        XCTAssertEqual(Array(data.prefix(2)), [0x04, 0x0B], file: file, line: line)
        XCTAssertEqual(AttributedBodyDecoder.decode(data), expect, file: file, line: line)
    }

    func testShortASCII() throws {
        try roundTrip(NSAttributedString(string: "See you at 6"), expect: "See you at 6")
    }

    func testEmojiAndMultibyte() throws {
        let s = "Café 👋🏽 日本語 — ok"
        try roundTrip(NSAttributedString(string: s), expect: s)
    }

    func testTwoByteLength() throws {
        let s = String(repeating: "abcdefghij", count: 40) // 400 bytes
        try roundTrip(NSAttributedString(string: s), expect: s)
    }

    func testFourByteLength() throws {
        let s = String(repeating: "0123456789🙂", count: 5000) // 70,000 UTF-8 bytes
        XCTAssertGreaterThan(s.utf8.count, 65_535)
        try roundTrip(NSAttributedString(string: s), expect: s)
    }

    func testMutableAttributedStringWithAttributes() throws {
        let m = NSMutableAttributedString(string: "Bold ")
        m.append(NSAttributedString(string: "move", attributes: [.init("__kIMMessagePartAttributeName"): 0]))
        try roundTrip(m, expect: "Bold move")
    }

    func testEmptyString() throws {
        try roundTrip(NSAttributedString(string: ""), expect: "")
    }

    func testGarbageAndTruncatedInputReturnNil() throws {
        XCTAssertNil(AttributedBodyDecoder.decode(Data()))
        XCTAssertNil(AttributedBodyDecoder.decode(Data([0x04, 0x0B])))
        XCTAssertNil(AttributedBodyDecoder.decode(Data((0..<512).map { UInt8($0 % 251) })))
        XCTAssertNil(AttributedBodyDecoder.decode(Data("NSString".utf8)))
        XCTAssertNil(AttributedBodyDecoder.decode(Data("NSString\u{01}\u{94}\u{84}\u{01}+".utf8)))
        XCTAssertNil(AttributedBodyDecoder.decode(Data("NSString+\u{81}\u{FF}".utf8)))

        let full = try XCTUnwrap(typedstream(NSAttributedString(string: String(repeating: "x", count: 300))))
        // Every truncation must be handled without crashing; cut inside the text -> nil.
        for cut in 0..<full.count {
            _ = AttributedBodyDecoder.decode(full.prefix(cut))
        }
        XCTAssertNil(AttributedBodyDecoder.decode(full.prefix(120)))

        // Invalid UTF-8 payload -> nil.
        var bad = try XCTUnwrap(typedstream(NSAttributedString(string: "abcd")))
        if let r = bad.range(of: Data("abcd".utf8)) { bad.replaceSubrange(r, with: [0xFF, 0xFE, 0xFF, 0xFE]) }
        XCTAssertNil(AttributedBodyDecoder.decode(bad))
    }
}
