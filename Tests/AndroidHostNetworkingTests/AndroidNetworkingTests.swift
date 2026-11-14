import AndroidHost
@testable import AndroidHostNetworking
import DynamicNetworking
import DynamicRuntime
import Testing

/// Sessions that record what they're asked to send.
final class FakeNetworkSystem: NetworkSystem {

    final class Call: NetworkCall {
        var cancelled = false
        func cancel() { cancelled = true }
    }

    final class Session: NetworkSessionSource {
        var started: [(TaskSpec, Int64, Call)] = []
        var closed = false
        var cookiesRemoved = false

        func start(_ task: TaskSpec, handle: Int64) -> any NetworkCall {
            let call = Call()
            started.append((task, handle, call))
            return call
        }

        func removeAllCookies() { cookiesRemoved = true }
        func removeAllCachedResponses() { }
        func close() { closed = true }
    }

    var state = NetworkState(isConnected: true)
    var sessions: [Session] = []
    var specs: [SessionSpec] = []
    var listening = false

    func makeSession(_ configuration: SessionSpec) -> any NetworkSessionSource {
        specs.append(configuration)
        let session = Session()
        sessions.append(session)
        return session
    }

    func networkState() -> NetworkState { state }

    func setConnectivityListening(_ on: Bool) { listening = on }
}

/// A guest-side task delegate.
final class RecordingTaskDelegate: HTTPTaskDelegate {

    var events: [String] = []
    var body: [UInt8] = []
    var followRedirects = true
    var credential: (any HTTPCredential)?
    var acceptResponse = true

    func willPerformRedirect(_ task: any HTTPTask, response: any HTTPResponse, newRequest: any HTTPRequest) -> Bool {
        events.append("redirect \(response.statusCode()) \(newRequest.method()) \(newRequest.url())")
        return followRedirects
    }

    func didReceiveChallenge(_ task: any HTTPTask, method: Int32, host: String, realm: String?, previousFailureCount: Int32) -> (any HTTPCredential)? {
        events.append("challenge \(method) \(host) \(realm ?? "-") \(previousFailureCount)")
        return credential
    }

    func didReceiveResponse(_ task: any HTTPTask, response: any HTTPResponse) -> Bool {
        events.append("response \(response.statusCode())")
        return acceptResponse
    }

    func didReceiveData(_ task: any HTTPTask, data: [UInt8]) {
        body += data
    }

    func didSendBodyData(_ task: any HTTPTask, bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        events.append("sent \(totalBytesSent)/\(totalBytesExpectedToSend)")
    }

    func taskIsWaitingForConnectivity(_ task: any HTTPTask) {
        events.append("waiting")
    }

    func didComplete(_ task: any HTTPTask, error: Int32, message: String?) {
        events.append("complete \(error)")
    }
}

/// Serialized: the hub is shared.
@Suite(.serialized) struct AndroidNetworkingTests {

    let system = FakeNetworkSystem()

    init() {
        NetworkHub.shared.use(system)
    }

    func request(_ url: String = "https://example.com/a") -> AndroidHTTPRequest {
        AndroidHTTPRequest.make(url: url)!
    }

    // MARK: Mappings

    @Test func validatesURLs() {
        #expect(NetworkMapping.isValidURL("https://example.com"))
        #expect(NetworkMapping.isValidURL("HTTP://user:pw@[::1]:8080/path?q#f"))
        #expect(!NetworkMapping.isValidURL("ftp://example.com"))
        #expect(!NetworkMapping.isValidURL("https:///path"))
        #expect(!NetworkMapping.isValidURL("example.com"))
        #expect(!NetworkMapping.isValidURL("https://exa mple.com"))
        #expect(AndroidHTTPRequest.make(url: "mailto:ada@example.com") == nil)
    }

    @Test func mapsErrors() {
        func error(_ exception: String, _ message: String = "") -> NetworkError {
            NetworkMapping.error(exception: exception, message: message)
        }
        #expect(error("java.net.UnknownHostException") == .cannotFindHost)
        #expect(error("java.net.ConnectException", "failed to connect") == .cannotConnectToHost)
        #expect(error("java.net.SocketTimeoutException", "timeout") == .timedOut)
        #expect(error("java.net.UnknownServiceException", "CLEARTEXT communication to x not permitted by network security policy") == .insecureConnectionNotAllowed)
        #expect(error("java.io.IOException", "Cleartext HTTP traffic to example.com not permitted") == .insecureConnectionNotAllowed)
        #expect(error("javax.net.ssl.SSLHandshakeException", "Trust anchor for certification path not found.") == .serverCertificateUntrusted)
        #expect(error("javax.net.ssl.SSLHandshakeException", "Handshake failed") == .secureConnectionFailed)
        #expect(error("java.net.ProtocolException", "Too many redirects") == .tooManyRedirects)
        #expect(error("java.net.ProtocolException", "Unexpected status line") == .badServerResponse)
        #expect(error("java.net.SocketException", "Connection reset") == .connectionLost)
        #expect(error("java.net.SocketException", "Network is unreachable") == .notConnectedToInternet)
        #expect(error("java.lang.IllegalStateException") == .unknown)
    }

    @Test func mapsCachingRedirectsAndChallenges() {
        #expect(NetworkMapping.cache(.useProtocolCachePolicy, ephemeral: false) == (true, nil))
        #expect(NetworkMapping.cache(.useProtocolCachePolicy, ephemeral: true) == (false, nil))
        #expect(NetworkMapping.cache(.reloadIgnoringLocalCacheData, ephemeral: false) == (false, "no-cache"))
        #expect(NetworkMapping.cache(.returnCacheDataDontLoad, ephemeral: false).cacheControl?.hasPrefix("only-if-cached") == true)
        #expect(NetworkMapping.redirectMethod(status: 302, method: "POST") == "GET")
        #expect(NetworkMapping.redirectMethod(status: 302, method: "PUT") == "PUT")
        #expect(NetworkMapping.redirectMethod(status: 303, method: "PUT") == "GET")
        #expect(NetworkMapping.redirectMethod(status: 303, method: "HEAD") == "HEAD")
        #expect(NetworkMapping.redirectMethod(status: 307, method: "POST") == "POST")
        #expect(NetworkMapping.challenge(#"Basic realm="Fake Realm""#, proxy: false) == (.basic, "Fake Realm"))
        #expect(NetworkMapping.challenge("Digest realm=r, nonce=\"x\"", proxy: false) == (.digest, "r"))
        #expect(NetworkMapping.challenge("Basic", proxy: true) == (.proxyBasic, nil))
        #expect(NetworkMapping.challenge("Negotiate", proxy: false).method == .other)
        #expect(NetworkMapping.mimeType("Text/HTML; charset=utf-8") == "text/html")
        #expect(NetworkMapping.mimeType(" ") == nil)
    }

    @Test func checksAccess() {
        func access(_ state: NetworkState, cellular: Bool = true, expensive: Bool = true, constrained: Bool = true, waits: Bool = false) -> NetworkMapping.Access {
            NetworkMapping.access(state, allowsCellular: cellular, allowsExpensive: expensive, allowsConstrained: constrained, waitsForConnectivity: waits)
        }
        #expect(access(NetworkState(isConnected: true)) == .proceed)
        #expect(access(NetworkState(isConnected: false)) == .fail(.notConnectedToInternet))
        #expect(access(NetworkState(isConnected: false), waits: true) == .wait)
        #expect(access(NetworkState(isConnected: true, isCellular: true, isMetered: true), cellular: false) == .fail(.networkAccessNotAllowed))
        #expect(access(NetworkState(isConnected: true, isMetered: true), expensive: false) == .fail(.networkAccessNotAllowed))
        #expect(access(NetworkState(isConnected: true, isDataSaver: true), constrained: false, waits: true) == .wait)
    }

    // MARK: Values

    @Test func keepsRequestsAndResponses() {
        let request = request()
        request.setMethod("post")
        request.setHeader("Accept", value: "a")
        request.setHeader("accept", value: "b")
        request.setHeader("X-One", value: "1")
        request.setTimeout(-1)
        request.setCachePolicy(9)
        #expect(request.method() == "POST")
        #expect(request.header("ACCEPT") == "b")
        #expect(request.headerNames() == ["accept", "X-One"])
        #expect(request.timeout() == 0)
        #expect(request.cachePolicy() == HTTPCachePolicy.useProtocolCachePolicy.rawValue)
        request.setHeader("X-One", value: nil)
        #expect(request.header("x-one") == nil)
        let response = AndroidHTTPResponse(status: 200, url: "https://example.com",
                                           headers: HeaderFields([("Set-Cookie", "a=1"), ("set-cookie", "b=2"),
                                                                  ("Content-Type", "application/json"), ("Content-Length", "42")]))
        #expect(response.header("SET-COOKIE") == "a=1, b=2")
        #expect(response.headerNames() == ["Set-Cookie", "Content-Type", "Content-Length"])
        #expect(response.mimeType() == "application/json")
        #expect(response.expectedContentLength() == 42)
        let compressed = AndroidHTTPResponse(status: 200, url: "", headers: HeaderFields([("Content-Encoding", "gzip"), ("Content-Length", "42")]))
        #expect(compressed.expectedContentLength() == -1)
    }

    @Test func copiesConfigurations() {
        let configuration = AndroidHTTPSessionConfiguration.makeEphemeral()
        configuration.setTimeoutForRequest(5)
        configuration.setTimeoutForRequest(-1)
        configuration.setMaximumConnectionsPerHost(0)
        configuration.setAdditionalHeader("User-Agent", value: "Check")
        let session = AndroidHTTPSession.make(configuration)
        configuration.setTimeoutForRequest(9)
        let copy = session.configuration()
        #expect(copy.timeoutForRequest() == 5)
        _ = session.source
        #expect(system.specs == [SessionSpec(ephemeral: true, shouldSetCookies: true, maximumConnections: 1)])
    }

    // MARK: Tasks

    @Test func sendsWhatTheRequestAndSessionSay() throws {
        let configuration = AndroidHTTPSessionConfiguration.makeDefault()
        configuration.setAdditionalHeader("User-Agent", value: "Session")
        configuration.setAdditionalHeader("X-Session", value: "1")
        configuration.setTimeoutForRequest(30)
        configuration.setCachePolicy(HTTPCachePolicy.reloadIgnoringLocalCacheData.rawValue)
        let session = AndroidHTTPSession.make(configuration)
        let request = request()
        request.setHeader("User-Agent", value: "Request")
        let delegate = RecordingTaskDelegate()
        let task = session.uploadTask(request, body: [1, 2, 3], delegate: delegate)
        #expect(task.state() == HTTPTaskState.suspended.rawValue)
        task.resume()
        let (spec, _, _) = try #require(system.sessions.first?.started.first)
        #expect(spec.url == "https://example.com/a")
        #expect(spec.body == [1, 2, 3])
        #expect(spec.isUpload)
        #expect(spec.timeout == 30_000)
        #expect(!spec.useCaches)
        #expect(spec.cacheControl == "no-cache")
        #expect(spec.headers.map(\.0) == ["User-Agent", "X-Session"])
        #expect(spec.headers.first?.1 == "Request", "the request's header wins")
        #expect(task.countOfBytesExpectedToSend() == 3)
        #expect(task.state() == HTTPTaskState.running.rawValue)
    }

    @Test func deliversEventsInOrder() throws {
        let delegate = RecordingTaskDelegate()
        let task = AndroidHTTPSession.shared().dataTask(request(), delegate: delegate)
        task.resume()
        let handle = try #require(system.sessions.first?.started.first?.1)
        let hub = NetworkHub.shared
        hub.response(handle: handle, status: 200, headers: [("Content-Length", "4")], url: "https://example.com/a")
        hub.data(handle: handle, [1, 2])
        hub.data(handle: handle, [3, 4])
        hub.complete(handle: handle, exception: "", message: "")
        #expect(delegate.events == ["response 200", "complete 0"])
        #expect(delegate.body == [1, 2, 3, 4])
        #expect(task.countOfBytesReceived() == 4)
        #expect(task.countOfBytesExpectedToReceive() == 4)
        #expect(task.state() == HTTPTaskState.completed.rawValue)
        #expect(hub.tasks.isEmpty, "released once complete")
        // Nothing more reaches a completed task.
        hub.data(handle: handle, [5])
        #expect(delegate.body.count == 4)
    }

    @Test func followsRedirectsAsTheGuestDecides() throws {
        let delegate = RecordingTaskDelegate()
        let request = request()
        request.setMethod("POST")
        request.setBody([1])
        request.setHeader("Content-Type", value: "text/plain")
        let task = AndroidHTTPSession.shared().dataTask(request, delegate: delegate)
        task.resume()
        let handle = try #require(system.sessions.first?.started.first?.1)
        let hub = NetworkHub.shared
        #expect(hub.redirect(handle: handle, status: 302, headers: [], url: "https://example.com/b") == "GET")
        #expect(task.currentRequest()?.url() == "https://example.com/b")
        #expect(task.currentRequest()?.body() == nil)
        #expect(task.currentRequest()?.header("Content-Type") == nil)
        #expect(task.originalRequest().method() == "POST")
        delegate.followRedirects = false
        #expect(hub.redirect(handle: handle, status: 307, headers: [], url: "https://example.com/c") == "")
        delegate.followRedirects = true
        for _ in 0..<NetworkMapping.maximumRedirects {
            _ = hub.redirect(handle: handle, status: 307, headers: [], url: "https://example.com/d")
        }
        #expect(hub.redirect(handle: handle, status: 307, headers: [], url: "https://example.com/e") == "!")
        hub.complete(handle: handle, exception: "java.net.ProtocolException", message: "Too many redirects")
        #expect(delegate.events.last == "complete \(NetworkError.tooManyRedirects.rawValue)")
    }

    @Test func answersChallenges() throws {
        let delegate = RecordingTaskDelegate()
        let session = AndroidHTTPSession.make(AndroidHTTPSessionConfiguration.makeDefault())
        let task = session.dataTask(request(), delegate: delegate)
        task.resume()
        let handle = try #require(system.sessions.first?.started.first?.1)
        let hub = NetworkHub.shared
        #expect(hub.challenge(handle: handle, header: #"Basic realm="R""#, proxy: false, host: "example.com", previousFailureCount: 0) == [])
        delegate.credential = AndroidHTTPCredential.make(user: "ada", password: "pw", persistence: HTTPCredentialPersistence.forSession.rawValue)
        #expect(hub.challenge(handle: handle, header: #"Basic realm="R""#, proxy: false, host: "example.com", previousFailureCount: 1) == ["ada", "pw"])
        #expect(delegate.events == ["challenge 0 example.com R 0", "challenge 0 example.com R 1"])
        // Kept for the session: the next task's first challenge doesn't ask.
        let next = session.dataTask(request(), delegate: delegate)
        next.resume()
        let nextHandle = try #require(system.sessions.first?.started.last?.1)
        #expect(hub.challenge(handle: nextHandle, header: #"Basic realm="R""#, proxy: false, host: "EXAMPLE.com", previousFailureCount: 0) == ["ada", "pw"])
        #expect(delegate.events.count == 2)
        // A digest challenge can't be answered with a password here.
        #expect(hub.challenge(handle: nextHandle, header: "Digest realm=\"D\"", proxy: false, host: "example.com", previousFailureCount: 0) == [])
    }

    @Test func cancels() throws {
        let delegate = RecordingTaskDelegate()
        let task = AndroidHTTPSession.shared().dataTask(request(), delegate: delegate)
        task.resume()
        let (_, handle, call) = try #require(system.sessions.first?.started.first)
        task.cancel()
        #expect(call.cancelled)
        #expect(task.state() == HTTPTaskState.canceling.rawValue)
        NetworkHub.shared.complete(handle: handle, exception: "java.net.SocketException", message: "Socket closed")
        #expect(delegate.events == ["complete \(NetworkError.cancelled.rawValue)"])
        // Refusing the response cancels too.
        let refusing = RecordingTaskDelegate()
        refusing.acceptResponse = false
        let second = AndroidHTTPSession.shared().dataTask(request(), delegate: refusing)
        second.resume()
        let (_, secondHandle, secondCall) = try #require(system.sessions.first?.started.last)
        NetworkHub.shared.response(handle: secondHandle, status: 200, headers: [], url: "https://example.com/a")
        #expect(secondCall.cancelled)
    }

    @Test func waitsForConnectivity() throws {
        system.state = NetworkState(isConnected: false)
        let failing = RecordingTaskDelegate()
        AndroidHTTPSession.shared().dataTask(request(), delegate: failing).resume()
        #expect(failing.events == ["complete \(NetworkError.notConnectedToInternet.rawValue)"])
        let configuration = AndroidHTTPSessionConfiguration.makeDefault()
        configuration.setWaitsForConnectivity(true)
        let delegate = RecordingTaskDelegate()
        let session = AndroidHTTPSession.make(configuration)
        session.dataTask(request(), delegate: delegate).resume()
        #expect(delegate.events == ["waiting"])
        #expect(system.listening)
        NetworkHub.shared.connectivityChanged()
        #expect(delegate.events == ["waiting"], "still offline, told once")
        system.state = NetworkState(isConnected: true)
        NetworkHub.shared.connectivityChanged()
        #expect(!system.listening)
        #expect(system.sessions.last?.started.count == 1)
    }

    @Test func invalidates() throws {
        let session = AndroidHTTPSession.make(AndroidHTTPSessionConfiguration.makeDefault())
        let delegate = RecordingTaskDelegate()
        let running = session.dataTask(request(), delegate: delegate)
        running.resume()
        let source = try #require(system.sessions.first)
        session.finishTasksAndInvalidate()
        let late = RecordingTaskDelegate()
        session.dataTask(request(), delegate: late).resume()
        #expect(late.events == ["complete \(NetworkError.sessionInvalidated.rawValue)"])
        #expect(!source.closed, "a task is still running")
        NetworkHub.shared.complete(handle: source.started[0].1, exception: "", message: "")
        #expect(source.closed)
        // The shared session can't be invalidated.
        AndroidHTTPSession.shared().invalidateAndCancel()
        #expect(AndroidHTTPSession.shared().isValid)
    }

    @Test func parsesURLs() throws {
        let url = try #require(AndroidURL.parse("HTTPS://ada@example.com:8443?q=a+b&q=%C3%A9&x#top"))
        #expect(url.scheme() == "https")
        #expect(url.user() == "ada")
        #expect(url.host() == "example.com")
        #expect(url.port() == 8443)
        #expect(url.path() == "/")
        #expect(url.query() == "q=a+b&q=%C3%A9&x")
        #expect(url.fragment() == "top")
        #expect(url.queryValues("q") == ["a b", "é"])
        #expect(url.queryValues("x") == [""])
        let page = try #require(AndroidURL.parse("https://example.com/guide/start/index.html"))
        #expect(page.resolve("../docs/a?b")?.absoluteString() == "https://example.com/guide/docs/a?b")
        #expect(page.resolve("//cdn.example.com/x")?.host() == "cdn.example.com")
        #expect(AndroidURL.parse("no scheme") == nil)
        #expect(AndroidURL.parse("/relative") == nil)
        #expect(AndroidURL.encodeQueryValue("a b&é~") == "a%20b%26%C3%A9~")
        #expect(AndroidURL.formDecode("100%") == "100%")
    }

    @Test func registersEveryContract() {
        #expect(AndroidHostNetworking.contracts.count == 8)
        #expect(AndroidHostNetworking.permissionProviders()[.network] is GrantedPermission)
    }
}
