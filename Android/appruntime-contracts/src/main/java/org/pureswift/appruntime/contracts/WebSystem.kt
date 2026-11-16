package org.pureswift.appruntime.contracts

import android.annotation.SuppressLint
import android.content.Context
import android.content.MutableContextWrapper
import android.graphics.Bitmap
import android.net.Uri
import android.net.http.SslError
import android.util.Log
import android.view.ViewGroup
import android.webkit.GeolocationPermissions
import android.webkit.MimeTypeMap
import android.webkit.PermissionRequest
import android.webkit.RenderProcessGoneDetail
import android.webkit.SslErrorHandler
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import java.io.ByteArrayInputStream
import java.io.IOException

/**
 * The `WebContent` contract's Android side (Documentation/Plan.md §6.4):
 * a `WebView` per page, made off screen, reporting through [WebNatives].
 * Swift's `AndroidWebContent` turns the reports into the contract's
 * events; the player's [WebPageView] shows a page where a `WebView` node
 * names it. Main thread only.
 */
class WebSystem {

    fun make(id: Int, network: Boolean) {
        pages[id] = WebPage(id, network)
    }

    fun destroy(id: Int) {
        pages.remove(id)?.destroy()
    }

    fun load(id: Int, url: String) {
        pages[id]?.view?.loadUrl(url)
    }

    fun loadHTML(id: Int, html: String, baseURL: String) {
        pages[id]?.view?.loadDataWithBaseURL(baseURL.ifEmpty { null }, html, "text/html", "utf-8", null)
    }

    fun loadResource(id: Int, url: String, directory: String, file: String): Boolean {
        val page = pages[id] ?: return false
        val path = WebPage.assetPath(directory, file)
        val exists = try {
            HostContext.application.assets.open(path).close()
            true
        } catch (error: IOException) {
            false
        }
        if (!exists) return false
        page.resources = directory
        page.view?.loadUrl(url)
        return true
    }

    fun reload(id: Int) {
        pages[id]?.view?.reload()
    }

    fun stopLoading(id: Int) {
        pages[id]?.view?.stopLoading()
    }

    fun goBack(id: Int) {
        pages[id]?.view?.goBack()
    }

    fun goForward(id: Int) {
        pages[id]?.view?.goForward()
    }

    fun evaluate(id: Int, script: String, request: Int) {
        val page = pages[id] ?: return
        page.view?.evaluateJavascript(script) { json -> WebNatives.evaluated(id, request, json ?: "null") }
    }

    internal companion object {
        /** Every page, by the ID its `WebView` node carries. */
        val pages = HashMap<Int, WebPage>()
    }
}

/** One page: its `WebView` and what its clients need to know. */
internal class WebPage(val id: Int, network: Boolean) {

    /** Lets the view's context follow the Activity, for dialogs. */
    private val context = MutableContextWrapper(HostContext.activity ?: HostContext.application)

    var view: WebView? = WebView(context)
        private set

    /** The bundle's resources directory the page may read, once it loaded one. */
    var resources: String? = null

    /** The main frame's URL, for certificate errors. */
    private var mainURL: String? = null

    init {
        configure(view!!, network)
    }

    /** The view moves to an Activity's window: dialogs use that Activity. */
    fun attach(activity: Context) {
        context.baseContext = activity
    }

    fun destroy() {
        val view = view ?: return
        this.view = null
        (view.parent as? ViewGroup)?.removeView(view)
        view.stopLoading()
        view.destroy()
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun configure(view: WebView, network: Boolean) {
        view.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            // New windows load in the same page.
            javaScriptCanOpenWindowsAutomatically = true
            setSupportMultipleWindows(false)
            allowFileAccess = false
            allowContentAccess = false
            // Without the network capability nothing remote loads.
            if (!network) blockNetworkLoads = true
        }
        view.webViewClient = Client()
        view.webChromeClient = Chrome()
    }

    private fun canGoBack() = view?.canGoBack() ?: false

    private fun canGoForward() = view?.canGoForward() ?: false

    private inner class Client : WebViewClient() {

        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
            !WebNatives.shouldNavigate(
                id, request.url.toString(), request.isForMainFrame, request.hasGesture(), request.isRedirect, request.method,
            )

        override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) {
            mainURL = url
            WebNatives.started(id, url)
        }

        override fun onPageFinished(view: WebView, url: String) {
            WebNatives.finished(id, url, canGoBack(), canGoForward())
        }

        override fun doUpdateVisitedHistory(view: WebView, url: String, isReload: Boolean) {
            WebNatives.history(id, url, canGoBack(), canGoForward())
        }

        override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
            if (request.isForMainFrame) WebNatives.error(id, error.errorCode, error.description.toString())
        }

        override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) {
            handler.cancel()
            if (error.url == mainURL) WebNatives.error(id, ERROR_FAILED_SSL_HANDSHAKE, "net::ERR_CERT: ${error.primaryError}")
        }

        override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? =
            resource(request.url)

        override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
            // The page can't go on, but the app can.
            Log.e("AppRuntime", "page $id: the web content process ${if (detail.didCrash()) "crashed" else "was stopped"}")
            WebNatives.error(id, ERROR_UNKNOWN, "the web content process stopped")
            destroy()
            return true
        }
    }

    private inner class Chrome : WebChromeClient() {

        override fun onProgressChanged(view: WebView, newProgress: Int) {
            WebNatives.progress(id, newProgress)
        }

        override fun onReceivedTitle(view: WebView, title: String?) {
            WebNatives.title(id, title ?: "")
        }

        // Pages get no camera, microphone or location.
        override fun onPermissionRequest(request: PermissionRequest) {
            request.deny()
        }

        override fun onGeolocationPermissionsShowPrompt(origin: String, callback: GeolocationPermissions.Callback) {
            callback.invoke(origin, false, false)
        }
    }

    /**
     * The bundle's resources, at `https://appassets.androidplatform.net/resources/…`:
     * the directory the page loaded from, and nothing else of the bundle.
     */
    private fun resource(url: Uri): WebResourceResponse? {
        if (url.host != RESOURCE_HOST) return null
        val directory = resources
        val path = url.path.orEmpty()
        val prefix = if (directory.isNullOrEmpty()) "/resources/" else "/resources/$directory/"
        val file = path.removePrefix(prefix)
        if (directory == null || !path.startsWith(prefix) || file.isEmpty() || file.split('/').any { it == ".." || it.isEmpty() }) {
            return notFound()
        }
        return try {
            val stream = HostContext.application.assets.open(assetPath(directory, file))
            val type = MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.substringAfterLast('.', "").lowercase())
                ?: "application/octet-stream"
            WebResourceResponse(type, null, stream)
        } catch (error: IOException) {
            notFound()
        }
    }

    private fun notFound() = WebResourceResponse("text/plain", "utf-8", 404, "Not Found", emptyMap(), ByteArrayInputStream(ByteArray(0)))

    companion object {
        const val RESOURCE_HOST = "appassets.androidplatform.net"

        /** Where the packager puts the bundle's resources in the APK's assets. */
        fun assetPath(directory: String, file: String) =
            if (directory.isEmpty()) "rt/resources/$file" else "rt/resources/$directory/$file"
    }
}

/**
 * Where a `WebView` node shows a page: the page's `WebView`, moved in from
 * wherever it was. The page stays loaded when the node goes.
 */
class WebPageView(context: Context) : FrameLayout(context) {

    /** The page shown: the node's `page` prop, or 0 for none. */
    var page: Int = 0
        set(value) {
            if (value == field) return
            release()
            field = value
            show()
        }

    private fun show() {
        val page = WebSystem.pages[page] ?: return
        val view = page.view ?: return
        (view.parent as? ViewGroup)?.removeView(view)
        page.attach(context)
        addView(view, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
    }

    private fun release() {
        val view = WebSystem.pages[page]?.view ?: return
        if (view.parent === this) removeView(view)
    }
}

/** What pages report to Swift's `WebHub`, on the main thread. */
object WebNatives {

    external fun started(id: Int, url: String)

    external fun progress(id: Int, percent: Int)

    external fun finished(id: Int, url: String, canGoBack: Boolean, canGoForward: Boolean)

    external fun history(id: Int, url: String, canGoBack: Boolean, canGoForward: Boolean)

    external fun title(id: Int, title: String)

    external fun error(id: Int, code: Int, description: String)

    external fun shouldNavigate(id: Int, url: String, isMainFrame: Boolean, hasGesture: Boolean, isRedirect: Boolean, method: String): Boolean

    external fun evaluated(id: Int, request: Int, json: String)
}
