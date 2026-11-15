import Foundation

/// Extracts the plain string from a `message.attributedBody` blob.
///
/// The blob is an NSArchiver "typedstream" of an NS(Mutable)AttributedString. The first object
/// archived is the backing string, whose class name (`NSString` / `NSMutableString`) appears in
/// full, followed shortly by a `+` (byte string) type marker, an encoded length and the UTF-8
/// bytes. Hand-parsed; every access is bounds-checked. (No NSUnarchiver fallback: it raises
/// Objective-C exceptions on malformed input, which Swift cannot catch.)
enum AttributedBodyDecoder {
    private static let classNames: [[UInt8]] = [Array("NSMutableString".utf8), Array("NSString".utf8)]
    /// How far past the class name we look for the `+` marker.
    private static let markerWindow = 32

    static func decode(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        guard let nameEnd = classNames.compactMap({ firstRange(of: $0, in: bytes) }).min() else { return nil }

        var i = nameEnd
        let windowEnd = min(bytes.count, nameEnd + markerWindow)
        while i < windowEnd, bytes[i] != 0x2B { i += 1 }
        guard i < windowEnd else { return nil }
        i += 1 // skip '+'

        guard i < bytes.count else { return nil }
        let length: Int
        switch bytes[i] {
        case 0x81:
            guard i + 2 < bytes.count else { return nil }
            length = Int(bytes[i + 1]) | Int(bytes[i + 2]) << 8
            i += 3
        case 0x82:
            guard i + 4 < bytes.count else { return nil }
            length = Int(bytes[i + 1]) | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3]) << 16 | Int(bytes[i + 4]) << 24
            i += 5
        case let b where b < 0x80:
            length = Int(b)
            i += 1
        default:
            return nil
        }

        guard length >= 0, i <= bytes.count, length <= bytes.count - i else { return nil }
        return String(bytes: bytes[i..<(i + length)], encoding: .utf8)
    }

    /// Index just past the first occurrence of `needle` in `haystack`.
    private static func firstRange(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let first = needle[0]
        var i = 0
        while i <= haystack.count - needle.count {
            if haystack[i] == first, haystack[i..<(i + needle.count)].elementsEqual(needle) {
                return i + needle.count
            }
            i += 1
        }
        return nil
    }
}
