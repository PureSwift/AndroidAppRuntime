import DynamicNetworking
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// `ParsedURL` (`org.pureswift.network.URL`) over swift-foundation's `URL`
/// and `URLComponents`, in Swift: no Kotlin needed.
///
/// They parse RFC 3986 rather than WHATWG URLs; as on Darwin, schemes are
/// lowercase, an `http` or `https` URL's empty path is `/`, and query
/// values decode `+` as a space.
public final class AndroidURL: ParsedURL {

    let url: URL

    private let components: URLComponents

    private init?(_ url: URL) {
        guard url.scheme != nil, let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return nil
        }
        self.url = url.absoluteURL
        self.components = components
    }

    public static func parse(_ string: String) -> AndroidURL? {
        URL(string: string).flatMap(AndroidURL.init)
    }

    public func resolve(_ reference: String) -> (any ParsedURL)? {
        URL(string: reference, relativeTo: url).flatMap { AndroidURL($0.absoluteURL) }
    }

    public func absoluteString() -> String {
        url.absoluteString
    }

    public func scheme() -> String {
        (components.scheme ?? "").lowercased()
    }

    public func user() -> String? {
        components.user
    }

    public func host() -> String? {
        components.host
    }

    public func port() -> Int32 {
        components.port.map { Int32(clamping: $0) } ?? -1
    }

    /// Percent-encoded, as in the URL.
    public func path() -> String {
        let path = components.percentEncodedPath
        if path.isEmpty, ["http", "https", "ws", "wss", "ftp"].contains(scheme()) {
            return "/"
        }
        return path
    }

    public func query() -> String? {
        components.percentEncodedQuery
    }

    public func fragment() -> String? {
        components.percentEncodedFragment
    }

    /// The query as `application/x-www-form-urlencoded`, as browsers read it.
    public func queryValues(_ name: String) -> [String] {
        guard let query = components.percentEncodedQuery else {
            return []
        }
        var values = [String]()
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard Self.formDecode(parts[0]) == name else { continue }
            values.append(parts.count > 1 ? Self.formDecode(parts[1]) : "")
        }
        return values
    }

    /// Leaves only RFC 3986's unreserved characters as they are.
    public static func encodeQueryValue(_ string: String) -> String {
        var encoded = ""
        for byte in string.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
                encoded.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                encoded += "%" + hex(byte)
            }
        }
        return encoded
    }

    /// `+` as a space, then percent escapes; a malformed escape stays as is.
    static func formDecode(_ part: Substring) -> String {
        var bytes: [UInt8] = []
        let utf8 = Array(part.utf8)
        var index = 0
        while index < utf8.count {
            let byte = utf8[index]
            if byte == UInt8(ascii: "+") {
                bytes.append(UInt8(ascii: " "))
            } else if byte == UInt8(ascii: "%"), index + 2 < utf8.count,
                      let high = hexValue(utf8[index + 1]), let low = hexValue(utf8[index + 2]) {
                bytes.append(high << 4 | low)
                index += 2
            } else {
                bytes.append(byte)
            }
            index += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func hex(_ byte: UInt8) -> String {
        let digits = Array("0123456789ABCDEF")
        return String([digits[Int(byte >> 4)], digits[Int(byte & 0xF)]])
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}
