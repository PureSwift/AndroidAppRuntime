import AndroidHost
import DynamicNetworking
import DynamicRuntime

/// Header fields, case-insensitive by name, in the order they were set.
struct HeaderFields: Equatable {

    private(set) var fields: [(name: String, value: String)] = []

    init(_ fields: [(String, String)] = []) {
        for (name, value) in fields {
            add(name, value)
        }
    }

    mutating func add(_ name: String, _ value: String) {
        fields.append((name, value))
    }

    /// Replaces every value of `name`, where it first was; nil removes it.
    mutating func set(_ name: String, _ value: String?) {
        let key = name.lowercased()
        let first = fields.firstIndex { $0.name.lowercased() == key }
        if let first, let value {
            fields[first] = (name, value)
            var index = fields.count - 1
            while index > first {
                if fields[index].name.lowercased() == key {
                    fields.remove(at: index)
                }
                index -= 1
            }
            return
        }
        fields.removeAll { $0.name.lowercased() == key }
        if let value {
            fields.append((name, value))
        }
    }

    /// The values joined with `, `, or nil.
    func value(_ name: String) -> String? {
        let key = name.lowercased()
        let values = fields.filter { $0.name.lowercased() == key }.map(\.value)
        return values.isEmpty ? nil : values.joined(separator: ", ")
    }

    /// Each name once, as first set.
    var names: [String] {
        var seen = Set<String>()
        return fields.compactMap { seen.insert($0.name.lowercased()).inserted ? $0.name : nil }
    }

    /// One pair per name, values joined.
    var joined: [(String, String)] {
        names.map { ($0, value($0) ?? "") }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.fields.elementsEqual(rhs.fields, by: ==)
    }
}

/// The `HTTPRequest` contract: a mutable request.
public final class AndroidHTTPRequest: HTTPRequest {

    private(set) var address: String

    private(set) var httpMethod = "GET"

    var headers = HeaderFields()

    private(set) var payload: [UInt8]?

    private(set) var seconds: Double = 0

    private(set) var policy = HTTPCachePolicy.useProtocolCachePolicy

    init(url: String) {
        self.address = url
    }

    /// A copy, for a task's original request and redirects.
    func copy(url: String? = nil) -> AndroidHTTPRequest {
        let copy = AndroidHTTPRequest(url: url ?? address)
        copy.httpMethod = httpMethod
        copy.headers = headers
        copy.payload = payload
        copy.seconds = seconds
        copy.policy = policy
        return copy
    }

    public static func make(url: String) -> AndroidHTTPRequest? {
        NetworkMapping.isValidURL(url) ? AndroidHTTPRequest(url: url) : nil
    }

    public func url() -> String { address }

    public func setMethod(_ method: String) {
        httpMethod = method.uppercased()
    }

    public func method() -> String { httpMethod }

    public func setHeader(_ name: String, value: String?) {
        headers.set(name, value)
    }

    public func header(_ name: String) -> String? {
        headers.value(name)
    }

    public func headerNames() -> [String] {
        headers.names
    }

    public func setBody(_ body: [UInt8]?) {
        payload = body
    }

    public func body() -> [UInt8]? { payload }

    public func setTimeout(_ seconds: Double) {
        self.seconds = seconds.isFinite ? max(0, seconds) : 0
    }

    public func timeout() -> Double { seconds }

    public func setCachePolicy(_ policy: Int32) {
        guard let policy = HTTPCachePolicy(rawValue: policy) else {
            HostLog.error("HTTPRequest.setCachePolicy: unknown policy \(policy)")
            return
        }
        self.policy = policy
    }

    public func cachePolicy() -> Int32 { policy.rawValue }

    /// Whether the guest set a cache policy other than the default, which
    /// the session's then replaces.
    var hasCachePolicy: Bool {
        policy != .useProtocolCachePolicy
    }
}

/// The `HTTPResponse` contract.
public final class AndroidHTTPResponse: HTTPResponse {

    let status: Int32

    let address: String

    let headers: HeaderFields

    init(status: Int32, url: String, headers: HeaderFields) {
        self.status = status
        self.address = url
        self.headers = headers
    }

    public func statusCode() -> Int32 { status }

    public func url() -> String { address }

    public func header(_ name: String) -> String? {
        headers.value(name)
    }

    public func headerNames() -> [String] {
        headers.names
    }

    /// `Content-Length`, unless the body is compressed, when
    /// `HttpURLConnection` hands over more bytes than it says.
    public func expectedContentLength() -> Int64 {
        guard headers.value("Content-Encoding") == nil, let length = headers.value("Content-Length"),
              let value = Int64(trimmed(Substring(length))) else {
            return -1
        }
        return value
    }

    public func mimeType() -> String? {
        NetworkMapping.mimeType(headers.value("Content-Type"))
    }
}

/// The `HTTPSessionConfiguration` contract: settings copied into a session
/// when it's made.
public final class AndroidHTTPSessionConfiguration: HTTPSessionConfiguration {

    struct Settings: Equatable {
        var ephemeral = false
        var timeoutForRequest: Double = 60
        var timeoutForResource: Double = 7 * 86_400
        var allowsCellular = true
        var allowsExpensive = true
        var allowsConstrained = true
        var waitsForConnectivity = false
        var shouldSetCookies = true
        var cachePolicy = HTTPCachePolicy.useProtocolCachePolicy
        var maximumConnectionsPerHost: Int32 = 6
        var additionalHeaders = HeaderFields()
    }

    var settings: Settings

    init(_ settings: Settings) {
        self.settings = settings
    }

    public static func makeDefault() -> AndroidHTTPSessionConfiguration {
        AndroidHTTPSessionConfiguration(Settings())
    }

    public static func makeEphemeral() -> AndroidHTTPSessionConfiguration {
        AndroidHTTPSessionConfiguration(Settings(ephemeral: true))
    }

    public func setTimeoutForRequest(_ seconds: Double) {
        guard seconds > 0, seconds.isFinite else { return }
        settings.timeoutForRequest = seconds
    }

    public func timeoutForRequest() -> Double { settings.timeoutForRequest }

    public func setTimeoutForResource(_ seconds: Double) {
        guard seconds > 0, seconds.isFinite else { return }
        settings.timeoutForResource = seconds
    }

    public func timeoutForResource() -> Double { settings.timeoutForResource }

    public func setAllowsCellularAccess(_ allowed: Bool) { settings.allowsCellular = allowed }

    public func setAllowsExpensiveNetworkAccess(_ allowed: Bool) { settings.allowsExpensive = allowed }

    public func setAllowsConstrainedNetworkAccess(_ allowed: Bool) { settings.allowsConstrained = allowed }

    public func setWaitsForConnectivity(_ waits: Bool) { settings.waitsForConnectivity = waits }

    public func setShouldSetCookies(_ enabled: Bool) { settings.shouldSetCookies = enabled }

    public func setCachePolicy(_ policy: Int32) {
        guard let policy = HTTPCachePolicy(rawValue: policy) else {
            HostLog.error("HTTPSessionConfiguration.setCachePolicy: unknown policy \(policy)")
            return
        }
        settings.cachePolicy = policy
    }

    public func setMaximumConnectionsPerHost(_ count: Int32) {
        settings.maximumConnectionsPerHost = max(1, count)
    }

    public func setAdditionalHeader(_ name: String, value: String?) {
        settings.additionalHeaders.set(name, value)
    }
}

/// The `HTTPCredential` contract. `permanent` is kept for the session:
/// Android has no shared credential store for apps.
public final class AndroidHTTPCredential: HTTPCredential {

    let name: String

    let password: String

    let persistenceCode: Int32

    init(user: String, password: String, persistence: Int32) {
        self.name = user
        self.password = password
        self.persistenceCode = persistence
    }

    public static func make(user: String, password: String, persistence: Int32) -> AndroidHTTPCredential {
        AndroidHTTPCredential(user: user, password: password, persistence: persistence)
    }

    public func user() -> String { name }

    public func persistence() -> Int32 { persistenceCode }
}
