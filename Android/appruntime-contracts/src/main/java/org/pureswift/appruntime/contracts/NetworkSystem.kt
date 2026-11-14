package org.pureswift.appruntime.contracts

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.http.HttpResponseCache
import android.util.Base64
import java.io.File
import java.io.InputStream
import java.net.CookieManager
import java.net.CookiePolicy
import java.net.HttpURLConnection
import java.net.ProtocolException
import java.net.URL
import java.util.concurrent.ExecutorService
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.FutureTask
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The Networking contracts' Android side (Swift's `AndroidHostNetworking`):
 * `HttpURLConnection` on each session's threads. Every event is posted to
 * the main thread, in order, for [NetworkNatives]; redirects and challenges
 * wait for Swift's answer there.
 */
class NetworkSystem {

    private val context: Context get() = HostContext.application

    private val connectivity: ConnectivityManager get() = context.getSystemService(ConnectivityManager::class.java)

    init {
        // The default configuration's response cache.
        if (HttpResponseCache.getInstalled() == null) installCache()
    }

    companion object {

        /** The app's `HttpResponseCache`, which default sessions use. */
        fun installCache() {
            val context = HostContext.application
            runCatching { HttpResponseCache.install(File(context.cacheDir, "appruntime-http"), 10L * 1024 * 1024) }
        }
    }

    fun makeSession(ephemeral: Boolean, cookies: Boolean, connections: Int): HttpSession =
        HttpSession(cookies, connections.coerceIn(1, 16))

    /** Connected, cellular, metered and Data Saver, as 1 or 0. */
    fun networkState(): IntArray = try {
        val capabilities = connectivity.activeNetwork?.let(connectivity::getNetworkCapabilities)
        val connected = capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
        val cellular = capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true
        val metered = capabilities != null && !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
        val saver = connectivity.restrictBackgroundStatus == ConnectivityManager.RESTRICT_BACKGROUND_STATUS_ENABLED
        intArrayOf(flag(connected), flag(cellular), flag(metered), flag(saver))
    } catch (error: SecurityException) {
        // Without ACCESS_NETWORK_STATE, assume a connection.
        intArrayOf(1, 0, 0, 0)
    }

    private fun flag(value: Boolean) = if (value) 1 else 0

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = NetworkNatives.connectivityChanged()
        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) = NetworkNatives.connectivityChanged()
        override fun onLost(network: Network) = NetworkNatives.connectivityChanged()
    }

    fun setConnectivityListening(on: Boolean) {
        try {
            if (on) connectivity.registerDefaultNetworkCallback(callback, HostContext.main)
            else connectivity.unregisterNetworkCallback(callback)
        } catch (error: RuntimeException) {
            // Not registered, or no ACCESS_NETWORK_STATE.
        }
    }
}

/** A session's threads and cookies. */
class HttpSession(private val cookies: Boolean, connections: Int) {

    private val executor: ExecutorService = Executors.newFixedThreadPool(connections) { runnable ->
        Thread(runnable, "AppRuntime HTTP").apply { isDaemon = true }
    }

    val cookieManager = CookieManager(null, CookiePolicy.ACCEPT_ORIGINAL_SERVER)

    /** Starts a request; its events carry `handle`. `body` is used when `hasBody`. */
    fun start(handle: Long, url: String, method: String, headerNames: Array<String>, headerValues: Array<String>,
              body: ByteArray, hasBody: Boolean, upload: Boolean, timeout: Int, useCaches: Boolean,
              cacheControl: String): HttpCall {
        val call = HttpCall(this, handle, url, method, headerNames.zip(headerValues).toMutableList(),
                            if (hasBody) body else null, upload, timeout, useCaches, cacheControl, cookies)
        executor.execute(call)
        return call
    }

    fun removeAllCookies() {
        cookieManager.cookieStore.removeAll()
    }

    /** Android's cache has no eviction: delete it and start a new one. */
    fun removeAllCachedResponses() {
        runCatching { HttpResponseCache.getInstalled()?.delete() }
        NetworkSystem.installCache()
    }

    fun close() {
        executor.shutdown()
    }
}

/** One request, run on a session thread. */
class HttpCall internal constructor(
    private val session: HttpSession,
    private val handle: Long,
    private var url: String,
    private var method: String,
    private val headers: MutableList<Pair<String, String>>,
    private var body: ByteArray?,
    private val upload: Boolean,
    private val timeout: Int,
    private val useCaches: Boolean,
    private val cacheControl: String,
    private val cookies: Boolean,
) : Runnable {

    private val started = AtomicBoolean(false)

    @Volatile private var cancelled = false

    @Volatile private var connection: HttpURLConnection? = null

    /** Disconnects; the task completes with the cancellation. */
    fun cancel() {
        cancelled = true
        if (!started.getAndSet(true)) {
            // It never ran: complete it here.
            post { NetworkNatives.complete(handle, "java.io.InterruptedIOException", "cancelled") }
        } else {
            connection?.disconnect()
        }
    }

    override fun run() {
        if (started.getAndSet(true)) return
        try {
            perform()
        } catch (error: Exception) {
            post { NetworkNatives.complete(handle, error.javaClass.name, error.message ?: "") }
        } finally {
            connection?.disconnect()
        }
    }

    private fun perform() {
        var authorization: String? = null
        var proxyAuthorization: String? = null
        var failures = 0
        var proxyFailures = 0
        while (true) {
            if (cancelled) throw java.io.InterruptedIOException("cancelled")
            val address = URL(url)
            val connection = address.openConnection() as HttpURLConnection
            this.connection = connection
            connection.instanceFollowRedirects = false
            connection.connectTimeout = timeout
            connection.readTimeout = timeout
            connection.useCaches = useCaches
            connection.requestMethod = method
            for ((name, value) in headers) connection.setRequestProperty(name, value)
            if (cacheControl.isNotEmpty()) connection.setRequestProperty("Cache-Control", cacheControl)
            authorization?.let { connection.setRequestProperty("Authorization", it) }
            proxyAuthorization?.let { connection.setRequestProperty("Proxy-Authorization", it) }
            if (cookies) {
                val stored = session.cookieManager.get(address.toURI(), emptyMap())["Cookie"].orEmpty()
                if (stored.isNotEmpty()) connection.setRequestProperty("Cookie", stored.joinToString("; "))
            }
            body?.let { send(connection, it) }

            val status = connection.responseCode
            val fields = connection.headerFields.filterKeys { it != null }
            if (cookies) runCatching { session.cookieManager.put(address.toURI(), fields) }
            val names = fields.flatMap { (name, values) -> values.map { name } }.toTypedArray()
            val values = fields.flatMap { it.value }.toTypedArray()

            // Redirects: Swift asks the guest, and says which method to use.
            val location = connection.getHeaderField("Location")
            if (status in 300..399 && status != 304 && location != null) {
                val next = URL(address, location).toString()
                val decision = ask { NetworkNatives.redirect(handle, status, names, values, next) }
                if (decision == "!") throw ProtocolException("Too many redirects")
                if (decision.isNotEmpty()) {
                    connection.disconnect()
                    url = next
                    if (decision != method) {
                        method = decision
                        if (method == "GET" || method == "HEAD") {
                            body = null
                            headers.removeAll { it.first.equals("Content-Type", true) || it.first.equals("Content-Length", true) }
                        }
                    }
                    continue
                }
            }

            // Challenges: a Basic credential from the guest, or the 401 / 407.
            val challenge = when (status) {
                401 -> connection.getHeaderField("WWW-Authenticate")
                407 -> connection.getHeaderField("Proxy-Authenticate")
                else -> null
            }
            if (challenge != null) {
                val proxy = status == 407
                val count = if (proxy) proxyFailures++ else failures++
                val credential = ask { NetworkNatives.challenge(handle, challenge, proxy, address.host, count) }
                if (credential.size == 2) {
                    val value = "Basic " + Base64.encodeToString("${credential[0]}:${credential[1]}".toByteArray(), Base64.NO_WRAP)
                    if (proxy) proxyAuthorization = value else authorization = value
                    connection.disconnect()
                    continue
                }
            }

            if (status == 504 && cacheControl.contains("only-if-cached")) {
                throw ProtocolException("only-if-cached")
            }
            post { NetworkNatives.response(handle, status, names, values, url) }
            val stream: InputStream? = if (status >= 400) connection.errorStream else connection.inputStream
            stream?.use { input ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    if (cancelled) throw java.io.InterruptedIOException("cancelled")
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (count > 0) {
                        val chunk = buffer.copyOf(count)
                        post { NetworkNatives.data(handle, chunk) }
                    }
                }
            }
            post { NetworkNatives.complete(handle, "", "") }
            return
        }
    }

    private fun send(connection: HttpURLConnection, body: ByteArray) {
        connection.doOutput = true
        connection.setFixedLengthStreamingMode(body.size)
        connection.outputStream.use { output ->
            var offset = 0
            while (offset < body.size) {
                if (cancelled) throw java.io.InterruptedIOException("cancelled")
                val count = minOf(16 * 1024, body.size - offset)
                output.write(body, offset, count)
                offset += count
                if (upload) {
                    val total = offset.toLong()
                    post { NetworkNatives.sent(handle, count.toLong(), total, body.size.toLong()) }
                }
            }
        }
    }

    private fun post(body: () -> Unit) {
        HostContext.main.post(Runnable { body() })
    }

    /** Runs `body` on the main thread and waits for its answer. */
    private fun <T> ask(body: () -> T): T {
        val task = FutureTask(Callable { body() })
        HostContext.main.post(task)
        return task.get()
    }
}

/** What the session threads report, on the main thread, for Swift's `NetworkHub`. */
object NetworkNatives {

    external fun connectivityChanged()

    /** The method to follow with, "" to stop at the redirect, or "!" for too many. */
    external fun redirect(handle: Long, status: Int, names: Array<String>, values: Array<String>, url: String): String

    /** A user and password, or nothing. */
    external fun challenge(handle: Long, header: String, proxy: Boolean, host: String, previousFailureCount: Int): Array<String>

    external fun response(handle: Long, status: Int, names: Array<String>, values: Array<String>, url: String)

    external fun data(handle: Long, bytes: ByteArray)

    external fun sent(handle: Long, bytes: Long, total: Long, expected: Long)

    /** `exception` is empty on success. */
    external fun complete(handle: Long, exception: String, message: String)
}
