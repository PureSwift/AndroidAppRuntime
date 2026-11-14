import AndroidHost
import DynamicNetworking
import DynamicRuntime

/// The `HTTPSession` contract over `HttpURLConnection` (`Plan.md` §6.2),
/// on the session's own threads, so it uses the platform's TLS, proxy and
/// network security config. Every event reaches the guest on the main
/// thread, in order; redirects and challenges ask the guest while the
/// thread waits.
///
/// - Cookies are the session's own, in memory, for both configurations.
/// - The default configuration uses the app's `HttpResponseCache`; an
///   ephemeral one uses none.
/// - Basic credentials answer challenges; digest challenges reach the
///   guest, but a credential for one can't be used, so the 401 is the
///   response.
public final class AndroidHTTPSession: HTTPSession {

    enum State {
        case valid
        /// `finishTasksAndInvalidate`: the running tasks finish.
        case finishing
        case invalidated
    }

    let settings: AndroidHTTPSessionConfiguration.Settings

    let isShared: Bool

    private(set) var state = State.valid

    private var lastIdentifier: Int64 = 0

    /// Tasks resumed and not complete.
    private(set) var running: [Int64: AndroidHTTPTask] = [:]

    /// Credentials kept for the session, by host and realm.
    private(set) var credentials: [String: AndroidHTTPCredential] = [:]

    private var _source: (any NetworkSessionSource)?

    var source: any NetworkSessionSource {
        if let _source {
            return _source
        }
        let source = NetworkHub.shared.system.makeSession(SessionSpec(
            ephemeral: settings.ephemeral, shouldSetCookies: settings.shouldSetCookies,
            maximumConnections: settings.maximumConnectionsPerHost
        ))
        _source = source
        return source
    }

    init(_ settings: AndroidHTTPSessionConfiguration.Settings, isShared: Bool = false) {
        self.settings = settings
        self.isShared = isShared
    }

    deinit {
        _source?.close()
    }

    nonisolated(unsafe) static var sharedSession: AndroidHTTPSession?

    public static func shared() -> AndroidHTTPSession {
        if let sharedSession {
            return sharedSession
        }
        let session = AndroidHTTPSession(AndroidHTTPSessionConfiguration.Settings(), isShared: true)
        sharedSession = session
        return session
    }

    public static func make(_ configuration: any HTTPSessionConfiguration) -> AndroidHTTPSession {
        guard let configuration = HostObjects.own(configuration, as: AndroidHTTPSessionConfiguration.self) else {
            HostLog.error("HTTPSession.make: a configuration from another host; using the default")
            return AndroidHTTPSession(AndroidHTTPSessionConfiguration.Settings())
        }
        return AndroidHTTPSession(configuration.settings)
    }

    public func configuration() -> any HTTPSessionConfiguration {
        AndroidHTTPSessionConfiguration(settings)
    }

    public func dataTask(_ request: any HTTPRequest, delegate: any HTTPTaskDelegate) -> any HTTPTask {
        makeTask(request, body: nil, delegate: delegate)
    }

    public func uploadTask(_ request: any HTTPRequest, body: [UInt8], delegate: any HTTPTaskDelegate) -> any HTTPTask {
        makeTask(request, body: body, delegate: delegate)
    }

    private func makeTask(_ request: any HTTPRequest, body: [UInt8]?, delegate: any HTTPTaskDelegate) -> AndroidHTTPTask {
        lastIdentifier += 1
        let original = HostObjects.own(request, as: AndroidHTTPRequest.self)?.copy() ?? Self.copy(request)
        if let body {
            original.setBody(body)
        }
        return AndroidHTTPTask(identifier: lastIdentifier, session: self, request: original, isUpload: body != nil, delegate: delegate)
    }

    /// A request from another host's objects, through the contract.
    static func copy(_ request: any HTTPRequest) -> AndroidHTTPRequest {
        let copy = AndroidHTTPRequest(url: request.url())
        copy.setMethod(request.method())
        for name in request.headerNames() {
            copy.setHeader(name, value: request.header(name))
        }
        copy.setBody(request.body())
        copy.setTimeout(request.timeout())
        copy.setCachePolicy(request.cachePolicy())
        return copy
    }

    public func finishTasksAndInvalidate() {
        guard !isShared, state == .valid else { return }
        state = .finishing
        closeIfDone()
    }

    public func invalidateAndCancel() {
        guard !isShared, state != .invalidated else { return }
        state = .finishing
        for task in running.values {
            task.cancel()
        }
        closeIfDone()
    }

    public func removeAllCookies() {
        source.removeAllCookies()
    }

    public func removeAllCachedResponses() {
        source.removeAllCachedResponses()
    }

    // MARK: Tasks

    var isValid: Bool {
        state == .valid
    }

    func started(_ task: AndroidHTTPTask) {
        running[task.identifier()] = task
    }

    func finished(_ task: AndroidHTTPTask) {
        running[task.identifier()] = nil
        closeIfDone()
    }

    private func closeIfDone() {
        guard state == .finishing, running.isEmpty else { return }
        state = .invalidated
        _source?.close()
        _source = nil
    }

    static func credentialKey(host: String, realm: String?) -> String {
        "\(host.lowercased())\u{0}\(realm ?? "")"
    }

    func credential(host: String, realm: String?) -> AndroidHTTPCredential? {
        credentials[Self.credentialKey(host: host, realm: realm)]
    }

    func keep(_ credential: AndroidHTTPCredential, host: String, realm: String?) {
        credentials[Self.credentialKey(host: host, realm: realm)] = credential
    }
}

/// Every running task, by handle, and the ones waiting for a connection.
/// Main thread only.
public final class NetworkHub {

    nonisolated(unsafe) public static let shared = NetworkHub()

    /// Makes the system on first use; `AndroidHostApp` sets it.
    public var makeSystem: (() -> any NetworkSystem)?

    private var _system: (any NetworkSystem)?

    public var system: any NetworkSystem {
        if let _system {
            return _system
        }
        guard let makeSystem else {
            fatalError("NetworkHub.makeSystem isn't set")
        }
        let system = makeSystem()
        _system = system
        return system
    }

    /// Kept strongly while they run, as URLSession keeps its tasks.
    private(set) var tasks: [Int64: AndroidHTTPTask] = [:]

    private(set) var waiting: [Int64: AndroidHTTPTask] = [:]

    private var lastHandle: Int64 = 0

    private var listening = false

    public init() { }

    /// Replaces the system, for tests.
    public func use(_ system: (any NetworkSystem)?) {
        _system = system
        tasks = [:]
        waiting = [:]
        listening = false
        AndroidHTTPSession.sharedSession = nil
    }

    func register(_ task: AndroidHTTPTask) -> Int64 {
        lastHandle += 1
        tasks[lastHandle] = task
        return lastHandle
    }

    func unregister(_ handle: Int64) {
        tasks[handle] = nil
    }

    func wait(_ task: AndroidHTTPTask) {
        lastHandle += 1
        waiting[lastHandle] = task
        task.waitingHandle = lastHandle
        updateListening()
    }

    func stopWaiting(_ task: AndroidHTTPTask) {
        if let handle = task.waitingHandle {
            waiting[handle] = nil
            task.waitingHandle = nil
        }
        updateListening()
    }

    private func updateListening() {
        let wanted = !waiting.isEmpty
        guard wanted != listening else { return }
        listening = wanted
        system.setConnectivityListening(wanted)
    }

    // MARK: Events

    /// The network changed: waiting tasks try again, in the order they
    /// started waiting.
    public func connectivityChanged() {
        for (_, task) in waiting.sorted(by: { $0.key < $1.key }) {
            task.retryAccess()
        }
    }

    public func redirect(handle: Int64, status: Int32, headers: [(String, String)], url: String) -> String {
        tasks[handle]?.redirect(status: status, headers: HeaderFields(headers), to: url) ?? ""
    }

    public func challenge(handle: Int64, header: String, proxy: Bool, host: String, previousFailureCount: Int32) -> [String] {
        tasks[handle]?.challenge(header: header, proxy: proxy, host: host, previousFailureCount: previousFailureCount) ?? []
    }

    public func response(handle: Int64, status: Int32, headers: [(String, String)], url: String) {
        tasks[handle]?.received(response: AndroidHTTPResponse(status: status, url: url, headers: HeaderFields(headers)))
    }

    public func data(handle: Int64, _ bytes: [UInt8]) {
        tasks[handle]?.received(data: bytes)
    }

    public func sent(handle: Int64, bytes: Int64, total: Int64, expected: Int64) {
        tasks[handle]?.sent(bytes: bytes, total: total, expected: expected)
    }

    /// `exception` is empty on success.
    public func complete(handle: Int64, exception: String, message: String) {
        tasks[handle]?.completed(exception: exception, message: message)
    }
}
