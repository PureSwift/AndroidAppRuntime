/// What the Networking contracts ask Android, through the Kotlin
/// `org.pureswift.appruntime.contracts.NetworkSystem` (`AndroidHostApp`
/// binds it): `HttpURLConnection` on a session's own threads, with its
/// events posted to the main thread, in order, for `NetworkHub`. Main
/// thread only.
public protocol NetworkSystem: AnyObject {

    /// A session's connection pool, cookies and threads.
    func makeSession(_ configuration: SessionSpec) -> any NetworkSessionSource

    /// The active network, for the configuration's access rules.
    func networkState() -> NetworkState

    /// `ConnectivityManager`'s callback: changes go to
    /// `NetworkHub.connectivityChanged`.
    func setConnectivityListening(_ on: Bool)
}

/// One session's side in Kotlin.
public protocol NetworkSessionSource: AnyObject {

    /// Starts a task on the session's threads; its events carry `handle`.
    func start(_ task: TaskSpec, handle: Int64) -> any NetworkCall

    func removeAllCookies()

    func removeAllCachedResponses()

    /// Stops the threads once the running tasks finish.
    func close()
}

/// A task in flight.
public protocol NetworkCall: AnyObject {

    /// Disconnects; the task completes with `cancelled`.
    func cancel()
}

/// What a session's Kotlin side needs.
public struct SessionSpec: Equatable, Sendable {

    /// Cookies and the response cache in memory only.
    public var ephemeral: Bool

    public var shouldSetCookies: Bool

    /// Threads, as URLSession's connections per host.
    public var maximumConnections: Int32

    public init(ephemeral: Bool, shouldSetCookies: Bool, maximumConnections: Int32) {
        self.ephemeral = ephemeral
        self.shouldSetCookies = shouldSetCookies
        self.maximumConnections = maximumConnections
    }
}

/// One request as `HttpURLConnection` sends it.
public struct TaskSpec: Equatable, Sendable {

    public var url: String

    public var method: String

    /// Name and value pairs; a header with several values is sent once,
    /// joined.
    public var headers: [(String, String)]

    public var body: [UInt8]?

    /// Report upload progress.
    public var isUpload: Bool

    /// Milliseconds, for the connection and each read.
    public var timeout: Int32

    public var useCaches: Bool

    /// Sent as `Cache-Control` when the request doesn't set one.
    public var cacheControl: String?

    public init(url: String, method: String, headers: [(String, String)], body: [UInt8]?, isUpload: Bool,
                timeout: Int32, useCaches: Bool, cacheControl: String?) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.isUpload = isUpload
        self.timeout = timeout
        self.useCaches = useCaches
        self.cacheControl = cacheControl
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.url == rhs.url && lhs.method == rhs.method && lhs.headers.elementsEqual(rhs.headers, by: ==)
            && lhs.body == rhs.body && lhs.isUpload == rhs.isUpload && lhs.timeout == rhs.timeout
            && lhs.useCaches == rhs.useCaches && lhs.cacheControl == rhs.cacheControl
    }
}

/// The active network, from `ConnectivityManager`.
public struct NetworkState: Equatable, Sendable {

    public var isConnected: Bool

    public var isCellular: Bool

    /// Not `NET_CAPABILITY_NOT_METERED`: cellular, or a hotspot.
    public var isMetered: Bool

    /// Data Saver is on for this app.
    public var isDataSaver: Bool

    public init(isConnected: Bool, isCellular: Bool = false, isMetered: Bool = false, isDataSaver: Bool = false) {
        self.isConnected = isConnected
        self.isCellular = isCellular
        self.isMetered = isMetered
        self.isDataSaver = isDataSaver
    }
}
