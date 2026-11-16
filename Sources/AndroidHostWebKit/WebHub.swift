import AndroidHost

/// Every page, by ID, and what their `WebView`s report: the Kotlin side's
/// `WebNatives` call these on the main thread. Main thread only.
public final class WebHub {

    nonisolated(unsafe) public static let shared = WebHub()

    /// Makes the system on first use; `AndroidHostApp` sets it.
    public var makeSystem: (() -> any WebSystem)?

    private var _system: (any WebSystem)?

    var system: any WebSystem {
        if let _system {
            return _system
        }
        guard let makeSystem else {
            fatalError("WebHub.makeSystem isn't set")
        }
        let system = makeSystem()
        _system = system
        return system
    }

    /// Whether pages may reach the network: the app declares `network`.
    public var network: () -> Bool = { AndroidBundle.info.capabilities.contains(.network) }

    private final class Entry {
        weak var page: AndroidWebContent?
        init(_ page: AndroidWebContent) {
            self.page = page
        }
    }

    private var pages: [Int32: Entry] = [:]

    private var nextID: Int32 = 1

    public init() { }

    /// Replaces the system, for tests.
    public func use(_ system: (any WebSystem)?) {
        _system = system
        pages = [:]
    }

    func register(_ page: AndroidWebContent) -> Int32 {
        let id = nextID
        nextID += 1
        pages[id] = Entry(page)
        return id
    }

    func unregister(_ id: Int32) {
        pages[id] = nil
    }

    private func page(_ id: Int32) -> AndroidWebContent? {
        pages[id]?.page
    }

    // MARK: From the views

    /// `onPageStarted` for the main frame.
    public func started(_ id: Int32, url: String) {
        page(id)?.started()
    }

    /// `onProgressChanged`, in percent.
    public func progress(_ id: Int32, percent: Int32) {
        page(id)?.progressed(Double(min(max(percent, 0), 100)) / 100)
    }

    /// `onPageFinished`, with where the history stands.
    public func finished(_ id: Int32, url: String, canGoBack: Bool, canGoForward: Bool) {
        page(id)?.finished(canGoBack: canGoBack, canGoForward: canGoForward)
    }

    /// `doUpdateVisitedHistory`: the main frame's URL changed.
    public func history(_ id: Int32, url: String, canGoBack: Bool, canGoForward: Bool) {
        page(id)?.visited(url, canGoBack: canGoBack, canGoForward: canGoForward)
    }

    /// `onReceivedTitle`.
    public func title(_ id: Int32, title: String) {
        page(id)?.titled(title)
    }

    /// `onReceivedError`, or a certificate error, for the main frame.
    public func error(_ id: Int32, code: Int32, description: String) {
        page(id)?.failed(code: code, description: description)
    }

    /// `shouldOverrideUrlLoading`: whether the navigation may go ahead.
    public func shouldNavigate(_ id: Int32, url: String, isMainFrame: Bool, hasGesture: Bool, isRedirect: Bool, method: String) -> Bool {
        page(id)?.shouldNavigate(url, isMainFrame: isMainFrame,
                                 kind: WebMapping.kind(hasGesture: hasGesture, isRedirect: isRedirect, method: method)) ?? false
    }

    /// `evaluateJavascript`'s result for `request`.
    public func evaluated(_ id: Int32, request: Int32, json: String) {
        page(id)?.evaluated(request, json: json)
    }
}
