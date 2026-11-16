import AndroidHost
import AndroidHostWebKit
import SwiftJava

/// The Kotlin `WebSystem` (`:appruntime-contracts`): one `WebView` per page.
@JavaClass("org.pureswift.appruntime.contracts.WebSystem")
open class JavaWebSystem: JavaObject {

    @JavaMethod
    @_nonoverride public convenience init(environment: JNIEnvironment? = nil)

    @JavaMethod open func make(_ id: Int32, _ network: Bool)
    @JavaMethod open func destroy(_ id: Int32)
    @JavaMethod open func load(_ id: Int32, _ url: String)
    @JavaMethod open func loadHTML(_ id: Int32, _ html: String, _ baseURL: String)
    @JavaMethod open func loadResource(_ id: Int32, _ url: String, _ directory: String, _ file: String) -> Bool
    @JavaMethod open func reload(_ id: Int32)
    @JavaMethod open func stopLoading(_ id: Int32)
    @JavaMethod open func goBack(_ id: Int32)
    @JavaMethod open func goForward(_ id: Int32)
    @JavaMethod open func evaluate(_ id: Int32, _ script: String, _ request: Int32)
}

extension JavaWebSystem: WebSystem {

    public func make(_ id: Int32, network: Bool) { make(id, network) }
    public func load(_ id: Int32, url: String) { load(id, url) }
    public func loadHTML(_ id: Int32, html: String, baseURL: String) { loadHTML(id, html, baseURL) }
    public func loadResource(_ id: Int32, url: String, directory: String, file: String) -> Bool {
        loadResource(id, url, directory, file)
    }
    public func evaluate(_ id: Int32, script: String, request: Int32) { evaluate(id, script, request) }
}

/// What the pages' `WebView`s report, on the main thread.
@JavaClass("org.pureswift.appruntime.contracts.WebNatives")
open class WebNatives: JavaObject {}

@JavaImplementation("org.pureswift.appruntime.contracts.WebNatives")
extension WebNatives {

    @JavaMethod
    public func started(_ id: Int32, _ url: String) {
        WebHub.shared.started(id, url: url)
    }

    @JavaMethod
    public func progress(_ id: Int32, _ percent: Int32) {
        WebHub.shared.progress(id, percent: percent)
    }

    @JavaMethod
    public func finished(_ id: Int32, _ url: String, _ canGoBack: Bool, _ canGoForward: Bool) {
        WebHub.shared.finished(id, url: url, canGoBack: canGoBack, canGoForward: canGoForward)
    }

    @JavaMethod
    public func history(_ id: Int32, _ url: String, _ canGoBack: Bool, _ canGoForward: Bool) {
        WebHub.shared.history(id, url: url, canGoBack: canGoBack, canGoForward: canGoForward)
    }

    @JavaMethod
    public func title(_ id: Int32, _ title: String) {
        WebHub.shared.title(id, title: title)
    }

    @JavaMethod
    public func error(_ id: Int32, _ code: Int32, _ description: String) {
        WebHub.shared.error(id, code: code, description: description)
    }

    @JavaMethod
    public func shouldNavigate(_ id: Int32, _ url: String, _ isMainFrame: Bool, _ hasGesture: Bool, _ isRedirect: Bool,
                               _ method: String) -> Bool {
        WebHub.shared.shouldNavigate(id, url: url, isMainFrame: isMainFrame, hasGesture: hasGesture,
                                     isRedirect: isRedirect, method: method)
    }

    @JavaMethod
    public func evaluated(_ id: Int32, _ request: Int32, _ json: String) {
        WebHub.shared.evaluated(id, request: request, json: json)
    }
}
