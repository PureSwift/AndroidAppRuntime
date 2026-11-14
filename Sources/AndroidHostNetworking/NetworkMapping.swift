import DynamicNetworking

/// The Networking contracts' rules over `HttpURLConnection`. Pure, so tests
/// check them on macOS.
enum NetworkMapping {

    // MARK: URLs and headers

    /// An absolute `http` or `https` URL with a host.
    static func isValidURL(_ url: String) -> Bool {
        let lower = url.lowercased()
        let rest: Substring
        if lower.hasPrefix("https://") {
            rest = url.dropFirst(8)
        } else if lower.hasPrefix("http://") {
            rest = url.dropFirst(7)
        } else {
            return false
        }
        let authority = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        let host = authority.split(separator: "@").last.map { hostPart in
            hostPart.hasPrefix("[") ? hostPart.prefix { $0 != "]" } : hostPart.prefix { $0 != ":" }
        } ?? ""
        return !host.isEmpty && !url.contains(" ")
    }

    /// The media type of a `Content-Type`, lowercased, without parameters.
    static func mimeType(_ contentType: String?) -> String? {
        guard let contentType else { return nil }
        let type = trimmed(contentType.prefix { $0 != ";" }).lowercased()
        return type.isEmpty ? nil : type
    }

    // MARK: Caching

    /// `HttpURLConnection.useCaches` and a `Cache-Control` for a policy,
    /// as `HttpResponseCache` understands them.
    static func cache(_ policy: HTTPCachePolicy, ephemeral: Bool) -> (useCaches: Bool, cacheControl: String?) {
        switch policy {
        case .useProtocolCachePolicy: (!ephemeral, nil)
        case .reloadIgnoringLocalCacheData: (false, "no-cache")
        case .returnCacheDataElseLoad: (!ephemeral, "max-stale=2147483647")
        case .returnCacheDataDontLoad: (!ephemeral, "only-if-cached, max-stale=2147483647")
        }
    }

    // MARK: Redirects

    /// The method a redirect uses: 303, and 301 or 302 after a `POST`,
    /// become `GET`, as browsers and URLSession do; 307 and 308 keep it.
    static func redirectMethod(status: Int32, method: String) -> String {
        switch status {
        case 303 where method != "HEAD": "GET"
        case 301, 302 where method == "POST": "GET"
        default: method
        }
    }

    /// How many redirects a task follows before `tooManyRedirects`, as
    /// URLSession.
    static let maximumRedirects = 16

    // MARK: Challenges

    /// The scheme and realm of a `WWW-Authenticate` or
    /// `Proxy-Authenticate` header.
    static func challenge(_ header: String, proxy: Bool) -> (method: HTTPAuthenticationMethod, realm: String?) {
        let scheme = header.prefix { $0 != " " }.lowercased()
        var realm: String?
        // Headers are ASCII, so the lowercased copy has the same offsets.
        let lower = header.lowercased()
        if let range = lower.firstRange(of: "realm="), lower.utf8.count == header.utf8.count {
            let offset = lower.utf8.distance(from: lower.startIndex, to: range.upperBound)
            var value = header[header.utf8.index(header.startIndex, offsetBy: offset)...]
            if value.hasPrefix("\"") {
                value = value.dropFirst().prefix { $0 != "\"" }
            } else {
                value = value.prefix { $0 != "," && $0 != " " }
            }
            realm = String(value)
        }
        switch scheme {
        case "basic": return (proxy ? .proxyBasic : .basic, realm)
        case "digest": return (proxy ? .other : .digest, realm)
        default: return (.other, realm)
        }
    }

    // MARK: Access

    enum Access: Equatable {
        case proceed
        /// No connection: wait for one.
        case wait
        case fail(NetworkError)
    }

    /// Whether a task may start on the network now.
    static func access(_ state: NetworkState, allowsCellular: Bool, allowsExpensive: Bool, allowsConstrained: Bool,
                       waitsForConnectivity: Bool) -> Access {
        guard state.isConnected else {
            return waitsForConnectivity ? .wait : .fail(.notConnectedToInternet)
        }
        if (state.isCellular && !allowsCellular) || (state.isMetered && !allowsExpensive)
            || (state.isDataSaver && !allowsConstrained) {
            return waitsForConnectivity ? .wait : .fail(.networkAccessNotAllowed)
        }
        return .proceed
    }

    // MARK: Errors

    /// A Java exception's class and message, as `HttpURLConnection` throws
    /// them, to the contract's code.
    static func error(exception: String, message: String) -> NetworkError {
        let name = exception.split(separator: ".").last.map(String.init) ?? exception
        let message = message.lowercased()
        // Android's network security policy: an `IOException` on API 28+,
        // `UnknownServiceException` in older OkHttp.
        if message.contains("cleartext") {
            return .insecureConnectionNotAllowed
        }
        switch name {
        case "UnknownHostException":
            return .cannotFindHost
        case "ConnectException", "NoRouteToHostException", "PortUnreachableException":
            return .cannotConnectToHost
        case "SocketTimeoutException", "InterruptedIOException" where message.contains("timeout") || message.contains("timed out"):
            return .timedOut
        case "SSLHandshakeException", "SSLPeerUnverifiedException", "CertificateException", "CertPathValidatorException":
            if message.contains("trust anchor") || message.contains("certif") || message.contains("hostname") {
                return .serverCertificateUntrusted
            }
            return .secureConnectionFailed
        case "SSLException", "SSLProtocolException":
            return .secureConnectionFailed
        case "ProtocolException":
            return message.contains("redirect") || message.contains("follow-up") ? .tooManyRedirects : .badServerResponse
        case "EOFException", "SocketException":
            if message.contains("network is unreachable") {
                return .notConnectedToInternet
            }
            return .connectionLost
        case "MalformedURLException", "URISyntaxException":
            return .invalidURL
        default:
            return .unknown
        }
    }
}

/// `text` without spaces and tabs around it.
func trimmed(_ text: Substring) -> Substring {
    var text = text
    while let first = text.first, first == " " || first == "\t" {
        text = text.dropFirst()
    }
    while let last = text.last, last == " " || last == "\t" {
        text = text.dropLast()
    }
    return text
}
