import AndroidHost
import DynamicNetworking
import DynamicRuntime

/// The `HTTPTask` contract: one request, from `resume()` to `didComplete`.
public final class AndroidHTTPTask: HTTPTask {

    private let id: Int64

    /// Kept until the task completes.
    private var session: AndroidHTTPSession?

    let original: AndroidHTTPRequest

    private(set) var current: AndroidHTTPRequest?

    let isUpload: Bool

    /// Kept until the task completes (the contract says so).
    private(set) var delegate: (any HTTPTaskDelegate)?

    private(set) var taskState = HTTPTaskState.suspended

    private(set) var received: AndroidHTTPResponse?

    private(set) var bytesSent: Int64 = 0

    private(set) var bytesReceived: Int64 = 0

    private var taskPriority: Float = 0.5

    private var call: (any NetworkCall)?

    private var handle: Int64?

    var waitingHandle: Int64?

    private var toldWaiting = false

    private var redirects = 0

    private var resourceTimer: TimerQueue.Token?

    /// The error a cancel completes with: `cancelled`, or `timedOut` for
    /// the resource timeout.
    private var cancelError = NetworkError.cancelled

    init(identifier: Int64, session: AndroidHTTPSession, request: AndroidHTTPRequest, isUpload: Bool, delegate: any HTTPTaskDelegate) {
        self.id = identifier
        self.session = session
        self.original = request
        self.isUpload = isUpload
        self.delegate = delegate
    }

    public func identifier() -> Int64 { id }

    public func state() -> Int32 { taskState.rawValue }

    public func originalRequest() -> any HTTPRequest { original }

    public func currentRequest() -> (any HTTPRequest)? { current }

    public func response() -> (any HTTPResponse)? { received }

    public func countOfBytesSent() -> Int64 { bytesSent }

    public func countOfBytesReceived() -> Int64 { bytesReceived }

    public func countOfBytesExpectedToSend() -> Int64 {
        original.body().map { Int64($0.count) } ?? -1
    }

    public func countOfBytesExpectedToReceive() -> Int64 {
        received?.expectedContentLength() ?? -1
    }

    public func setPriority(_ priority: Float) {
        taskPriority = min(1, max(0, priority))
    }

    public func priority() -> Float { taskPriority }

    // MARK: Running

    public func resume() {
        guard taskState == .suspended, let session else { return }
        taskState = .running
        session.started(self)
        guard session.isValid else {
            complete(.sessionInvalidated, message: "The session was invalidated.")
            return
        }
        let resource = session.settings.timeoutForResource
        resourceTimer = MainLooper.shared.schedule(after: Int64(min(resource, 1e9) * 1e9)) { [weak self] in
            self?.resourceTimedOut()
        }
        retryAccess()
    }

    /// Starts if the network allows it; otherwise waits or fails.
    func retryAccess() {
        guard taskState == .running, call == nil, let session else { return }
        let settings = session.settings
        let access = NetworkMapping.access(NetworkHub.shared.system.networkState(), allowsCellular: settings.allowsCellular,
                                           allowsExpensive: settings.allowsExpensive, allowsConstrained: settings.allowsConstrained,
                                           waitsForConnectivity: settings.waitsForConnectivity)
        switch access {
        case .proceed:
            NetworkHub.shared.stopWaiting(self)
            start(session)
        case .wait:
            if waitingHandle == nil {
                NetworkHub.shared.wait(self)
            }
            if !toldWaiting {
                toldWaiting = true
                delegate?.taskIsWaitingForConnectivity(self)
            }
        case .fail(let error):
            NetworkHub.shared.stopWaiting(self)
            complete(error, message: error == .notConnectedToInternet ? "The Internet connection appears to be offline." : "The configuration doesn't allow this network.")
        }
    }

    /// What `HttpURLConnection` sends: the session's additional headers
    /// under the request's, and the cache policy as `useCaches` and
    /// `Cache-Control`.
    func spec(_ settings: AndroidHTTPSessionConfiguration.Settings) -> TaskSpec {
        var headers = settings.additionalHeaders
        for (name, value) in original.headers.joined {
            headers.set(name, value)
        }
        let policy = original.hasCachePolicy ? HTTPCachePolicy(rawValue: original.cachePolicy())! : settings.cachePolicy
        let cache = NetworkMapping.cache(policy, ephemeral: settings.ephemeral)
        let seconds = original.timeout() > 0 ? original.timeout() : settings.timeoutForRequest
        return TaskSpec(url: original.url(), method: original.method(), headers: headers.joined, body: original.body(),
                        isUpload: isUpload, timeout: Int32(min(seconds * 1000, Double(Int32.max))),
                        useCaches: cache.useCaches, cacheControl: original.header("Cache-Control") == nil ? cache.cacheControl : nil)
    }

    private func start(_ session: AndroidHTTPSession) {
        current = original.copy()
        let handle = NetworkHub.shared.register(self)
        self.handle = handle
        call = session.source.start(spec(session.settings), handle: handle)
    }

    public func cancel() {
        switch taskState {
        case .suspended:
            taskState = .canceling
            // Completes later, as URLSession does.
            MainLooper.shared.post { [self] in
                complete(.cancelled, message: "cancelled")
            }
        case .running:
            taskState = .canceling
            if let call {
                call.cancel()
            } else {
                NetworkHub.shared.stopWaiting(self)
                complete(cancelError, message: "cancelled")
            }
        case .canceling, .completed:
            break
        }
    }

    private func resourceTimedOut() {
        resourceTimer = nil
        guard taskState == .running else { return }
        cancelError = .timedOut
        cancel()
    }

    // MARK: Events

    /// A redirect: the new method, or "" to stop at the redirect, or "!"
    /// when there were too many.
    func redirect(status: Int32, headers: HeaderFields, to url: String) -> String {
        guard taskState == .running, let current else { return "" }
        redirects += 1
        guard redirects <= NetworkMapping.maximumRedirects else { return "!" }
        let response = AndroidHTTPResponse(status: status, url: current.url(), headers: headers)
        let next = current.copy(url: url)
        let method = NetworkMapping.redirectMethod(status: status, method: current.method())
        if method != current.method() {
            next.setMethod(method)
            next.setBody(nil)
            next.setHeader("Content-Type", value: nil)
            next.setHeader("Content-Length", value: nil)
        }
        guard delegate?.willPerformRedirect(self, response: response, newRequest: next) ?? true else {
            return ""
        }
        self.current = next
        return next.method()
    }

    /// A 401 or 407: a Basic credential's user and password, or nothing for
    /// the default handling.
    func challenge(header: String, proxy: Bool, host: String, previousFailureCount: Int32) -> [String] {
        guard taskState == .running, let session else { return [] }
        let (method, realm) = NetworkMapping.challenge(header, proxy: proxy)
        if previousFailureCount == 0, let kept = session.credential(host: host, realm: realm) {
            return [kept.name, kept.password]
        }
        guard let answer = delegate?.didReceiveChallenge(self, method: method.rawValue, host: host, realm: realm,
                                                         previousFailureCount: previousFailureCount) else {
            return []
        }
        guard let credential = HostObjects.own(answer, as: AndroidHTTPCredential.self) else {
            HostLog.error("HTTPTaskDelegate.didReceiveChallenge: a credential from another host")
            return []
        }
        guard method == .basic || method == .proxyBasic else {
            HostLog.warning("HTTPTask: only Basic credentials can answer a challenge on Android; the response is the \(proxy ? 407 : 401)")
            return []
        }
        if credential.persistenceCode != HTTPCredentialPersistence.none.rawValue {
            session.keep(credential, host: host, realm: realm)
        }
        return [credential.name, credential.password]
    }

    func received(response: AndroidHTTPResponse) {
        guard taskState == .running else { return }
        received = response
        if delegate?.didReceiveResponse(self, response: response) == false {
            cancel()
        }
    }

    func received(data: [UInt8]) {
        guard taskState == .running else { return }
        bytesReceived += Int64(data.count)
        delegate?.didReceiveData(self, data: data)
    }

    func sent(bytes: Int64, total: Int64, expected: Int64) {
        guard taskState == .running else { return }
        bytesSent = total
        delegate?.didSendBodyData(self, bytesSent: bytes, totalBytesSent: total, totalBytesExpectedToSend: expected)
    }

    /// The call ended: `exception` is empty on success.
    func completed(exception: String, message: String) {
        if taskState == .canceling {
            complete(cancelError, message: "cancelled")
        } else if exception.isEmpty {
            complete(nil, message: nil)
        } else {
            var error = NetworkMapping.error(exception: exception, message: message)
            if error == .badServerResponse, message == "only-if-cached" {
                error = .resourceUnavailable
            }
            if error == .unknown {
                HostLog.warning("HTTPTask \(id) failed: \(exception): \(message)")
            }
            complete(error, message: message.isEmpty ? exception : message)
        }
    }

    private func complete(_ error: NetworkError?, message: String?) {
        guard taskState != .completed else { return }
        taskState = .completed
        if let resourceTimer {
            MainLooper.shared.cancel(resourceTimer)
            self.resourceTimer = nil
        }
        if let handle {
            NetworkHub.shared.unregister(handle)
        }
        NetworkHub.shared.stopWaiting(self)
        call = nil
        let delegate = delegate
        self.delegate = nil
        delegate?.didComplete(self, error: error?.rawValue ?? 0, message: error == nil ? nil : message)
        session?.finished(self)
        session = nil
    }
}

/// The Networking contracts (`Plan.md` §6.2). `network` is granted on
/// Android: `INTERNET` is an install-time permission.
public enum AndroidHostNetworking: HostModule {

    public static var contracts: [ContractDescriptor] {
        [
            HTTPSessionProxy.descriptor, HTTPSessionConfigurationProxy.descriptor, HTTPRequestProxy.descriptor,
            HTTPResponseProxy.descriptor, HTTPTaskProxy.descriptor, HTTPTaskDelegateProxy.descriptor,
            HTTPCredentialProxy.descriptor, ParsedURLProxy.descriptor,
        ]
    }

    public static func register(in registrar: some ContractRegistrar) {
        HTTPSessionProxy.register(AndroidHTTPSession.self, in: registrar)
        HTTPSessionConfigurationProxy.register(AndroidHTTPSessionConfiguration.self, in: registrar)
        HTTPRequestProxy.register(AndroidHTTPRequest.self, in: registrar)
        HTTPResponseProxy.register(AndroidHTTPResponse.self, in: registrar)
        HTTPTaskProxy.register(AndroidHTTPTask.self, in: registrar)
        HTTPTaskDelegateProxy.registerInterface(in: registrar)
        HTTPCredentialProxy.register(AndroidHTTPCredential.self, in: registrar)
        ParsedURLProxy.register(AndroidURL.self, in: registrar)
    }

    public static func permissionProviders() -> [Capability: any PermissionProvider] {
        [.network: GrantedPermission()]
    }
}
