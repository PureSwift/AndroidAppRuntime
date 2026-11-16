import AndroidHost
@testable import AndroidHostWebKit
import DynamicRuntime
import DynamicWebKit
import Testing

/// Android's WebView as the tests set it up: it writes down what it's
/// asked.
final class FakeWebSystem: WebSystem {

    var calls: [String] = []
    var resources: Set<String> = []

    func make(_ id: Int32, network: Bool) { calls.append("make \(id) network \(network)") }
    func destroy(_ id: Int32) { calls.append("destroy \(id)") }
    func load(_ id: Int32, url: String) { calls.append("load \(url)") }
    func loadHTML(_ id: Int32, html: String, baseURL: String) { calls.append("html \(html) base \(baseURL)") }
    func loadResource(_ id: Int32, url: String, directory: String, file: String) -> Bool {
        calls.append("resource \(url) in \(directory.isEmpty ? "." : directory)")
        return resources.contains(directory.isEmpty ? file : "\(directory)/\(file)")
    }
    func reload(_ id: Int32) { calls.append("reload") }
    func stopLoading(_ id: Int32) { calls.append("stop") }
    func goBack(_ id: Int32) { calls.append("back") }
    func goForward(_ id: Int32) { calls.append("forward") }
    func evaluate(_ id: Int32, script: String, request: Int32) {
        calls.append(script.hasPrefix("(function(){") ? "evaluate wrapped \(request)" : "evaluate \(script) \(request)")
    }
}

/// A delegate that writes down each call.
final class RecordingPage: WebContentDelegate {

    var events: [String] = []
    var allow = true

    func shouldNavigate(_ content: any WebContent, url: String, kind: Int32, isMainFrame: Bool) -> Bool {
        events.append("should \(url) kind \(kind) main \(isMainFrame)")
        return allow
    }
    func didChangeURL(_ content: any WebContent, url: String?) { events.append("url \(url ?? "nil")") }
    func didChangeTitle(_ content: any WebContent, title: String) { events.append("title \(title)") }
    func didChangeLoading(_ content: any WebContent, isLoading: Bool, progress: Double) {
        events.append("loading \(isLoading) \(progress)")
    }
    func didChangeHistory(_ content: any WebContent, canGoBack: Bool, canGoForward: Bool) {
        events.append("history \(canGoBack) \(canGoForward)")
    }
    func didFinishNavigation(_ content: any WebContent) { events.append("finish") }
    func didFailNavigation(_ content: any WebContent, error: Int32, message: String) { events.append("fail \(error)") }
    func didEvaluateJavaScript(_ content: any WebContent, request: Int32, result: String?, error: String?) {
        events.append("script \(request) \(result ?? "nil") \(error ?? "nil")")
    }
}

func scene(network: Bool = true) -> (WebHub, FakeWebSystem, RecordingPage, AndroidWebContent) {
    let hub = WebHub()
    let system = FakeWebSystem()
    hub.use(system)
    hub.network = { network }
    let delegate = RecordingPage()
    let page = AndroidWebContent(delegate: delegate, hub: hub)
    return (hub, system, delegate, page)
}

@Suite("Web pages")
struct WebContentTests {

    @Test func aPageIsMadeOffScreenAndDestroyedWhenReleased() {
        let hub = WebHub()
        let system = FakeWebSystem()
        hub.use(system)
        hub.network = { false }
        var page: AndroidWebContent? = AndroidWebContent(delegate: RecordingPage(), hub: hub)
        #expect(page?.identifier() == 1)
        page = nil
        #expect(system.calls == ["make 1 network false", "destroy 1"])
        #expect(AndroidWebContent(delegate: RecordingPage(), hub: hub).identifier() == 2)
    }

    @Test func aLoadReportsEachChangeOnceAndInOrder() {
        let (hub, system, delegate, page) = scene()
        page.load("https://swift.org/")
        #expect(system.calls.last == "load https://swift.org/")
        // Android's progress can come first, and repeat.
        hub.progress(page.id, percent: 10)
        hub.started(page.id, url: "https://swift.org/")
        hub.progress(page.id, percent: 10)
        hub.history(page.id, url: "https://www.swift.org/", canGoBack: false, canGoForward: false)
        hub.title(page.id, title: "Swift.org")
        hub.progress(page.id, percent: 70)
        hub.progress(page.id, percent: 100)
        hub.finished(page.id, url: "https://www.swift.org/", canGoBack: false, canGoForward: false)
        // onPageFinished can come twice.
        hub.finished(page.id, url: "https://www.swift.org/", canGoBack: false, canGoForward: false)
        #expect(delegate.events == [
            "loading true 0.1",
            "url https://www.swift.org/",
            "title Swift.org",
            "loading true 0.7",
            "loading true 1.0",
            "loading false 1.0",
            "finish",
        ])
    }

    @Test func aFailureComesBeforeTheEndOfLoadingAndIsntAFinish() {
        let (hub, _, delegate, page) = scene()
        hub.started(page.id, url: "https://nowhere.invalid/")
        hub.error(page.id, code: -2, description: "net::ERR_NAME_NOT_RESOLVED")
        hub.error(page.id, code: -2, description: "net::ERR_NAME_NOT_RESOLVED")
        hub.finished(page.id, url: "https://nowhere.invalid/", canGoBack: false, canGoForward: false)
        #expect(delegate.events == ["loading true 0.0", "fail 2", "loading false 1.0"])
        // The next load starts afresh.
        hub.started(page.id, url: "https://swift.org/")
        hub.finished(page.id, url: "https://swift.org/", canGoBack: true, canGoForward: false)
        #expect(delegate.events.suffix(4) == ["loading true 0.0", "history true false", "loading false 1.0", "finish"])
    }

    @Test func aCancelledNavigationOnlyEndsLoading() {
        let (hub, system, delegate, page) = scene()
        hub.started(page.id, url: "https://swift.org/")
        hub.error(page.id, code: -1, description: "net::ERR_ABORTED")
        page.stopLoading()
        hub.finished(page.id, url: "https://swift.org/", canGoBack: false, canGoForward: false)
        #expect(system.calls.last == "stop")
        #expect(delegate.events == ["loading true 0.0", "loading false 1.0"])
    }

    @Test func withoutNetworkNothingRemoteLoads() {
        let (hub, system, delegate, page) = scene(network: false)
        #expect(system.calls == ["make 1 network false"])
        page.load("https://swift.org/")
        #expect(system.calls.count == 1, "never started")
        #expect(delegate.events == ["fail 7", "loading false 1.0"])
        // A link from a local page is refused without asking.
        #expect(!hub.shouldNavigate(page.id, url: "http://example.com/", isMainFrame: true, hasGesture: true, isRedirect: false, method: "GET"))
        #expect(!delegate.events.contains { $0.hasPrefix("should") })
        // Local content works.
        page.loadHTML("<p>Hi</p>", baseURL: nil)
        page.load("about:blank")
        #expect(system.calls.suffix(2) == ["html <p>Hi</p> base ", "load about:blank"])
        #expect(hub.shouldNavigate(page.id, url: "https://\(WebMapping.resourceHost)/resources/b.html", isMainFrame: true,
                                   hasGesture: true, isRedirect: false, method: "GET"))
    }

    @Test func theGuestDecidesNavigations() {
        let (hub, _, delegate, page) = scene()
        #expect(hub.shouldNavigate(page.id, url: "https://swift.org/blog", isMainFrame: true, hasGesture: true, isRedirect: false, method: "GET"))
        delegate.allow = false
        #expect(!hub.shouldNavigate(page.id, url: "tel:123", isMainFrame: false, hasGesture: false, isRedirect: false, method: "GET"))
        #expect(delegate.events == ["should https://swift.org/blog kind 0 main true", "should tel:123 kind 4 main false"])
    }

    @Test func historyGatesBackAndForward() {
        let (hub, system, _, page) = scene()
        page.goBack()
        page.goForward()
        #expect(!system.calls.contains("back"))
        hub.history(page.id, url: "https://swift.org/a", canGoBack: true, canGoForward: false)
        page.goBack()
        page.goForward()
        #expect(system.calls.suffix(1) == ["back"])
    }

    @Test func resourcesComeFromTheBundleOnly() {
        let (_, system, delegate, page) = scene(network: false)
        system.resources = ["help/index.html", "about.html"]
        page.loadResource("help/index.html")
        page.loadResource("about.html")
        #expect(system.calls.suffix(2) == [
            "resource https://appassets.androidplatform.net/resources/help/index.html in help",
            "resource https://appassets.androidplatform.net/resources/about.html in .",
        ])
        #expect(delegate.events.isEmpty)
        page.loadResource("missing.html")
        page.loadResource("../Info.plist")
        #expect(delegate.events == ["fail 5", "loading false 1.0", "fail 5", "loading false 1.0"])
    }

    @Test func scriptResultsAreJSONAndExceptionsAreErrors() {
        let (hub, system, delegate, page) = scene()
        page.evaluateJavaScript("document.links.length", request: 1)
        page.evaluateJavaScript("undefined", request: 2)
        page.evaluateJavaScript("throw new Error('no')", request: 3)
        page.evaluateJavaScript("document.title", request: 4)
        #expect(system.calls.suffix(4) == ["evaluate wrapped 1", "evaluate wrapped 2", "evaluate wrapped 3", "evaluate wrapped 4"])
        hub.evaluated(page.id, request: 1, json: #""v42""#)
        hub.evaluated(page.id, request: 2, json: #""u""#)
        hub.evaluated(page.id, request: 3, json: #""eno""#)
        hub.evaluated(page.id, request: 4, json: #""v\"Swift.org\"""#)
        #expect(delegate.events == ["script 1 42 nil", "script 2 nil nil", "script 3 nil no", #"script 4 "Swift.org" nil"#])
    }

    @Test func aPageThatForbidsEvalRunsTheScriptAsItIs() {
        let (hub, system, delegate, page) = scene()
        page.evaluateJavaScript("document.links.length", request: 9)
        hub.evaluated(page.id, request: 9, json: #""c""#)
        #expect(system.calls.last == "evaluate document.links.length 9")
        #expect(delegate.events.isEmpty)
        hub.evaluated(page.id, request: 9, json: "12")
        #expect(delegate.events == ["script 9 12 nil"])
    }

    @Test func aTitleThatIsOnlyTheURLIsEmpty() {
        let (hub, _, delegate, page) = scene()
        hub.history(page.id, url: "https://example.com/", canGoBack: false, canGoForward: false)
        hub.title(page.id, title: "example.com")
        hub.title(page.id, title: "Example Domain")
        #expect(delegate.events == ["url https://example.com/", "title Example Domain"])
    }
}

@Suite("Web mapping")
struct WebMappingTests {

    @Test func remoteURLs() {
        #expect(WebMapping.isRemote("https://swift.org"))
        #expect(WebMapping.isRemote("HTTP://example.com/a"))
        #expect(WebMapping.isRemote("wss://example.com/socket"))
        #expect(!WebMapping.isRemote("about:blank"))
        #expect(!WebMapping.isRemote("data:text/html,hi"))
        #expect(!WebMapping.isRemote("tel:123"))
        #expect(!WebMapping.isRemote("https://appassets.androidplatform.net/resources/a.html"))
        #expect(WebMapping.isRemote("https://appassets.androidplatform.net.evil.com/"))
        #expect(WebMapping.isRemote("https://appassets.androidplatform.net@evil.com/") == true)
    }

    @Test func resourcePaths() {
        #expect(WebMapping.resource("/help/./index.html")?.directory == "help")
        #expect(WebMapping.resource("a/b/c.html")?.url == "https://appassets.androidplatform.net/resources/a/b/c.html")
        #expect(WebMapping.resource("../secret") == nil)
        #expect(WebMapping.resource("a/../../b") == nil)
        #expect(WebMapping.resource("") == nil)
    }

    @Test func errors() {
        #expect(WebMapping.error(code: -2, description: "net::ERR_NAME_NOT_RESOLVED") == .network)
        #expect(WebMapping.error(code: -8, description: "") == .timedOut)
        #expect(WebMapping.error(code: -11, description: "") == .security)
        #expect(WebMapping.error(code: -1, description: "net::ERR_CLEARTEXT_NOT_PERMITTED") == .security)
        #expect(WebMapping.error(code: -1, description: "net::ERR_INTERNET_DISCONNECTED") == .network)
        #expect(WebMapping.error(code: -10, description: "net::ERR_UNKNOWN_URL_SCHEME") == .badURL)
        #expect(WebMapping.error(code: -1, description: "net::ERR_ABORTED") == nil)
        #expect(WebMapping.error(code: -1, description: "net::ERR_FAILED") == .unknown)
    }

    @Test func navigationKinds() {
        #expect(WebMapping.kind(hasGesture: true, isRedirect: false, method: "GET") == .linkActivated)
        #expect(WebMapping.kind(hasGesture: true, isRedirect: true, method: "GET") == .other)
        #expect(WebMapping.kind(hasGesture: false, isRedirect: false, method: "post") == .formSubmitted)
        #expect(WebMapping.kind(hasGesture: false, isRedirect: false, method: "GET") == .other)
    }

    @Test func jsonStringsRoundTrip() {
        let text = "a \"quote\", a \\ backslash,\nlines\u{2028}, \u{1} and 😀"
        let json = WebMapping.jsonString(text)
        #expect(!json.contains("\n"))
        #expect(json.contains("\\u2028"))
        #expect(WebMapping.decodeJSONString(json) == text)
        #expect(WebMapping.decodeJSONString(#""😀 é""#) == "😀 é")
        #expect(WebMapping.decodeJSONString("null") == nil)
        #expect(WebMapping.decodeJSONString(#""\x""#) == nil)
    }

    @Test func wrappedScriptsKeepTheirSource() {
        let wrapped = WebMapping.wrap("document.title + \"!\"")
        #expect(wrapped.contains(#"(0,eval)("document.title + \"!\"")"#))
        #expect(WebMapping.outcome(wrapped: "null")! == (nil, "the script didn't run"))
        #expect(WebMapping.outcome(plain: "null") == (nil, nil))
    }
}
