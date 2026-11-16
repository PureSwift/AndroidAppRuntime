import AndroidHost
import DynamicRuntime
import DynamicWebKit

/// The `WebContent` contract: a page in Android's `WebView`, made off
/// screen and shown where a `WebView` node names its `identifier()`.
///
/// Android reports a load in pieces (`onPageStarted`, progress,
/// `onReceivedError`, `onPageFinished`, `doUpdateVisitedHistory`); this
/// turns them into the contract's events, each once and in order.
public final class AndroidWebContent: WebContent {

    let delegate: any WebContentDelegate

    let hub: WebHub

    /// `identifier()`: never reused.
    public private(set) var id: Int32 = 0

    /// Whether the app declares `network`.
    let network: Bool

    // What the guest last heard.
    private(set) var url: String?
    private(set) var title = ""
    private(set) var isLoading = false
    private(set) var progress = 0.0
    private(set) var canGoBack = false
    private(set) var canGoForward = false

    /// The main frame failed since loading started: what Android says
    /// after that isn't a finish.
    private var failed = false

    /// Scripts waiting for their results, and whether each was wrapped.
    private var scripts: [Int32: (script: String, wrapped: Bool)] = [:]

    init(delegate: any WebContentDelegate, hub: WebHub = .shared) {
        self.delegate = delegate
        self.hub = hub
        network = hub.network()
        id = hub.register(self)
        hub.system.make(id, network: network)
    }

    deinit {
        hub.unregister(id)
        hub.system.destroy(id)
    }

    public static func make(_ delegate: any WebContentDelegate) -> AndroidWebContent {
        AndroidWebContent(delegate: delegate)
    }

    public func identifier() -> Int32 {
        id
    }

    // MARK: Loading

    public func load(_ url: String) {
        guard network || !WebMapping.isRemote(url) else {
            notPermitted(url)
            return
        }
        hub.system.load(id, url: url)
    }

    public func loadHTML(_ html: String, baseURL: String?) {
        hub.system.loadHTML(id, html: html, baseURL: baseURL ?? "")
    }

    public func loadResource(_ path: String) {
        guard let resource = WebMapping.resource(path),
              hub.system.loadResource(id, url: resource.url, directory: resource.directory, file: resource.file) else {
            fail(.badURL, "\(path) isn't in the app's resources")
            return
        }
    }

    public func reload() {
        hub.system.reload(id)
    }

    /// A stopped load isn't a failure: only the loading state changes.
    public func stopLoading() {
        hub.system.stopLoading(id)
        if isLoading {
            isLoading = false
            progress = 1
            delegate.didChangeLoading(self, isLoading: false, progress: 1)
        }
    }

    public func goBack() {
        if canGoBack {
            hub.system.goBack(id)
        }
    }

    public func goForward() {
        if canGoForward {
            hub.system.goForward(id)
        }
    }

    // MARK: Scripts

    public func evaluateJavaScript(_ script: String, request: Int32) {
        scripts[request] = (script, true)
        hub.system.evaluate(id, script: WebMapping.wrap(script), request: request)
    }

    func evaluated(_ request: Int32, json: String) {
        guard let pending = scripts.removeValue(forKey: request) else { return }
        let outcome: (result: String?, error: String?)
        if pending.wrapped {
            guard let wrapped = WebMapping.outcome(wrapped: json) else {
                // The page forbids eval: run it as it is.
                scripts[request] = (pending.script, false)
                hub.system.evaluate(id, script: pending.script, request: request)
                return
            }
            outcome = wrapped
        } else {
            outcome = WebMapping.outcome(plain: json)
        }
        delegate.didEvaluateJavaScript(self, request: request, result: outcome.result, error: outcome.error)
    }

    // MARK: From the view

    func started() {
        failed = false
        guard !isLoading else { return }
        isLoading = true
        progress = 0
        delegate.didChangeLoading(self, isLoading: true, progress: 0)
    }

    func progressed(_ value: Double) {
        if !isLoading {
            // Progress can come before onPageStarted; 100 comes after.
            guard value < 1 else { return }
            failed = false
            isLoading = true
        } else if value == progress {
            return
        }
        progress = value
        delegate.didChangeLoading(self, isLoading: true, progress: value)
    }

    func finished(canGoBack: Bool, canGoForward: Bool) {
        updateHistory(canGoBack: canGoBack, canGoForward: canGoForward)
        guard isLoading, !failed else { return }
        isLoading = false
        progress = 1
        delegate.didChangeLoading(self, isLoading: false, progress: 1)
        delegate.didFinishNavigation(self)
    }

    func visited(_ url: String, canGoBack: Bool, canGoForward: Bool) {
        if url != self.url {
            self.url = url
            delegate.didChangeURL(self, url: url)
        }
        updateHistory(canGoBack: canGoBack, canGoForward: canGoForward)
    }

    func titled(_ title: String) {
        let title = WebMapping.title(title, url: url)
        guard title != self.title else { return }
        self.title = title
        delegate.didChangeTitle(self, title: title)
    }

    func failed(code: Int32, description: String) {
        guard !failed, let error = WebMapping.error(code: code, description: description) else { return }
        fail(error, description)
    }

    func shouldNavigate(_ url: String, isMainFrame: Bool, kind: WebNavigationKind) -> Bool {
        guard network || !WebMapping.isRemote(url) else {
            if isMainFrame {
                notPermitted(url)
            }
            return false
        }
        return delegate.shouldNavigate(self, url: url, kind: kind.rawValue, isMainFrame: isMainFrame)
    }

    private func updateHistory(canGoBack: Bool, canGoForward: Bool) {
        guard canGoBack != self.canGoBack || canGoForward != self.canGoForward else { return }
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        delegate.didChangeHistory(self, canGoBack: canGoBack, canGoForward: canGoForward)
    }

    private func notPermitted(_ url: String) {
        fail(.notPermitted, "\(url) is remote, and the app doesn't declare the network capability")
    }

    /// The main frame failed: the failure, then loading ends.
    private func fail(_ error: WebError.Code, _ message: String) {
        failed = true
        isLoading = false
        progress = 1
        delegate.didFailNavigation(self, error: error.rawValue, message: message)
        delegate.didChangeLoading(self, isLoading: false, progress: 1)
    }
}

/// The WebKit contracts (`Plan.md` §6.4). `WebContent` needs no capability;
/// `network` lets pages reach the network.
public enum AndroidHostWebKit: HostModule {

    public static var contracts: [ContractDescriptor] {
        [WebContentProxy.descriptor, WebContentDelegateProxy.descriptor]
    }

    public static func register(in registrar: some ContractRegistrar) {
        WebContentProxy.register(AndroidWebContent.self, in: registrar)
        WebContentDelegateProxy.registerInterface(in: registrar)
    }
}
