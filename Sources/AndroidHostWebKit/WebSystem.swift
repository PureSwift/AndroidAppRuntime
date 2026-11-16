/// What a page asks of Android's `WebView` (`Plan.md` §6.4): the Kotlin
/// `WebSystem`, one `WebView` per page ID. Tests use a fake. Main thread
/// only; what the views report comes back through `WebHub`.
public protocol WebSystem: AnyObject {

    /// Makes page `id`'s `WebView`, off screen. Without `network` it loads
    /// nothing from the network.
    func make(_ id: Int32, network: Bool)

    /// Takes the view off screen and destroys it.
    func destroy(_ id: Int32)

    func load(_ id: Int32, url: String)

    /// `loadDataWithBaseURL`; an empty `baseURL` is none.
    func loadHTML(_ id: Int32, html: String, baseURL: String)

    /// Loads `url`, which `WebMapping.resource` made, serving the bundle's
    /// `resources/<directory>` at its path and nothing else of the bundle.
    /// False if there's no such file.
    func loadResource(_ id: Int32, url: String, directory: String, file: String) -> Bool

    func reload(_ id: Int32)

    func stopLoading(_ id: Int32)

    func goBack(_ id: Int32)

    func goForward(_ id: Int32)

    /// `evaluateJavascript`; the result, the JSON Android makes of the
    /// script's value, comes back as `WebHub.evaluated` with `request`.
    func evaluate(_ id: Int32, script: String, request: Int32)
}
