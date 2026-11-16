import DynamicWebKit

/// Android's `WebView` values as the `WebContent` contract has them
/// (AppRuntime's Contracts/WebKit.md).
public enum WebMapping {

    // MARK: URLs

    /// Where the bundle's resources are served from: `WebViewAssetLoader`'s
    /// domain, which never reaches the network.
    public static let resourceHost = "appassets.androidplatform.net"

    /// Whether loading `url` needs the network: http, https, WebSocket and
    /// FTP URLs, except the bundle's resources.
    public static func isRemote(_ url: String) -> Bool {
        guard let colon = url.firstIndex(of: ":") else { return false }
        let scheme = url[..<colon].lowercased()
        guard ["http", "https", "ws", "wss", "ftp"].contains(scheme) else { return false }
        return host(url)?.lowercased() != resourceHost
    }

    static func host(_ url: String) -> String? {
        guard let start = url.firstRange(of: "://")?.upperBound else { return nil }
        var host = url[start...].prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        if let at = host.lastIndex(of: "@") {
            host = host[host.index(after: at)...]
        }
        return String(host.prefix { $0 != ":" })
    }

    /// A bundle resource's URL and the directory the page may read, for a
    /// path in `resources/`; nil for a path that leaves it.
    public static func resource(_ path: String) -> (url: String, directory: String, file: String)? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        guard let file = parts.last, !parts.contains("..") else { return nil }
        let directory = parts.dropLast().joined(separator: "/")
        let prefix = directory.isEmpty ? "/resources/" : "/resources/\(directory)/"
        return ("https://\(resourceHost)\(prefix)\(file)", directory, String(file))
    }

    // MARK: Navigations

    /// What started a navigation `shouldOverrideUrlLoading` asks about.
    /// Android doesn't ask for back, forward or reload.
    public static func kind(hasGesture: Bool, isRedirect: Bool, method: String) -> WebNavigationKind {
        if isRedirect {
            return .other
        }
        if method.uppercased() == "POST" {
            return .formSubmitted
        }
        return hasGesture ? .linkActivated : .other
    }

    /// `WebViewClient.ERROR_*` and the description Chromium gives, as
    /// `WebError.Code`; nil for a navigation that was only cancelled or
    /// replaced, which isn't a failure.
    public static func error(code: Int32, description: String) -> WebError.Code? {
        if description.contains("ERR_ABORTED") {
            return nil
        }
        switch code {
        case -2, -6, -7, -5, -15: return .network
        case -8: return .timedOut
        case -11, -16, -3, -4: return .security
        case -10, -12, -13, -14: return .badURL
        default:
            if description.contains("CLEARTEXT_NOT_PERMITTED") || description.contains("ERR_CERT") || description.contains("ERR_SSL") {
                return .security
            }
            if description.contains("ERR_INTERNET_DISCONNECTED") || description.contains("ERR_NAME_NOT_RESOLVED")
                || description.contains("ERR_ADDRESS_UNREACHABLE") || description.contains("ERR_CONNECTION") {
                return .network
            }
            if description.contains("ERR_TIMED_OUT") {
                return .timedOut
            }
            if description.contains("ERR_UNKNOWN_URL_SCHEME") || description.contains("ERR_INVALID_URL")
                || description.contains("ERR_FILE_NOT_FOUND") {
                return .badURL
            }
            return .unknown
        }
    }

    /// `onReceivedTitle` gives the URL when a page has no title; the
    /// contract's title is empty then, as on the other hosts.
    public static func title(_ title: String, url: String?) -> String {
        guard let url, !title.isEmpty else { return title }
        var bare = Substring(url)
        if let scheme = url.firstRange(of: "://") {
            bare = url[scheme.upperBound...]
        }
        return title == url || title == bare || title + "/" == bare ? "" : title
    }

    // MARK: Scripts

    /// The script, wrapped so its outcome comes back as one string:
    /// `v` and its value as JSON, `u` for a value JSON can't hold, `e` and
    /// an exception's message, or `c` when the page's content security
    /// policy forbids `eval`. The indirect eval runs it in the global scope
    /// and gives the value of its last statement, as WebKit does.
    public static func wrap(_ script: String) -> String {
        """
        (function(){var r;try{r=(0,eval)(\(jsonString(script)))}catch(e){\
        if(e instanceof EvalError)return "c";\
        return "e"+String(e&&e.message!==undefined?e.message:e)}\
        try{var j=JSON.stringify(r);return j===undefined?"u":"v"+j}catch(e){return "u"}})()
        """
    }

    /// The outcome of a wrapped script, from the JSON `evaluateJavascript`
    /// gave: its result and error, or nil when the page forbids `eval` and
    /// the script must run unwrapped.
    public static func outcome(wrapped json: String) -> (result: String?, error: String?)? {
        guard let text = decodeJSONString(json), let tag = text.first else {
            return (nil, "the script didn't run")
        }
        let rest = String(text.dropFirst())
        switch tag {
        case "v": return (rest, nil)
        case "u": return (nil, nil)
        case "e": return (nil, rest.isEmpty ? "the script threw" : rest)
        case "c": return nil
        default: return (nil, "the script didn't run")
        }
    }

    /// The outcome of a script that ran unwrapped: Android's JSON, which
    /// can't tell `undefined` or an exception from `null`.
    public static func outcome(plain json: String) -> (result: String?, error: String?) {
        (json == "null" ? nil : json, nil)
    }

    /// `text` as a JSON string literal, which is also a JavaScript one.
    public static func jsonString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            case _ where scalar.value < 0x20:
                let hex = String(scalar.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// A JSON string literal's text; nil if `json` isn't one.
    public static func decodeJSONString(_ json: String) -> String? {
        let scalars = Array(json.unicodeScalars)
        guard scalars.count >= 2, scalars.first == "\"", scalars.last == "\"" else { return nil }
        var out = String.UnicodeScalarView()
        var index = 1
        let end = scalars.count - 1
        func hex4() -> UInt32? {
            guard index + 4 <= end else { return nil }
            let digits = String(String.UnicodeScalarView(scalars[index..<index + 4]))
            index += 4
            return UInt32(digits, radix: 16)
        }
        while index < end {
            let scalar = scalars[index]
            index += 1
            guard scalar == "\\" else {
                out.append(scalar)
                continue
            }
            guard index < end else { return nil }
            let escape = scalars[index]
            index += 1
            switch escape {
            case "\"", "\\", "/": out.append(escape)
            case "b": out.append("\u{8}")
            case "f": out.append("\u{C}")
            case "n": out.append("\n")
            case "r": out.append("\r")
            case "t": out.append("\t")
            case "u":
                guard var value = hex4() else { return nil }
                if (0xD800..<0xDC00).contains(value), index + 6 <= end, scalars[index] == "\\", scalars[index + 1] == "u" {
                    index += 2
                    guard let low = hex4(), (0xDC00..<0xE000).contains(low) else { return nil }
                    value = 0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00)
                }
                out.append(Unicode.Scalar(value) ?? "\u{FFFD}")
            default: return nil
            }
        }
        return String(out)
    }
}
