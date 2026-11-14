import DynamicNetworking
import DynamicRuntime

/// `HTTPSession` against httpbin.org (the emulator needs the Internet):
/// headers, a redirect, an upload, Basic authentication, an error status,
/// an unknown host, plain HTTP (which Android blocks), and a cancel. One
/// request at a time.
final class NetworkCheck {

    let report: Report

    let session: HTTPSession

    private var steps: [() -> Void] = []

    private var current: Fetch?

    init(report: Report) {
        self.report = report
        self.session = HTTPSessionProxy.shared()
    }

    func run() {
        report.check(HTTPRequestProxy.make(url: "ftp://example.com") == nil, "network.request rejects ftp")
        steps = [get, redirect, upload, authenticate, notFound, unknownHost, cleartext, cancel]
        next()
    }

    private func next() {
        guard !steps.isEmpty else {
            report.note("network.done")
            return
        }
        steps.removeFirst()()
    }

    private func fetch(_ url: String, method: String = "GET", body: [UInt8]? = nil, configure: (HTTPRequest) -> Void = { _ in },
                       then check: @escaping (Fetch) -> Void) -> HTTPTask? {
        guard let request = HTTPRequestProxy.make(url: url) else {
            report.check(false, "network.request \(url)")
            next()
            return nil
        }
        request.setMethod(method)
        configure(request)
        let fetch = Fetch { [self] fetch in
            check(fetch)
            current = nil
            next()
        }
        current = fetch
        let task = body.map { session.uploadTask(request, body: $0, delegate: fetch) } ?? session.dataTask(request, delegate: fetch)
        task.resume()
        return task
    }

    private func get() {
        _ = fetch("https://httpbin.org/get", configure: { $0.setHeader("X-Check", value: "AppRuntime") }) { [report] fetch in
            report.check(fetch.error == 0 && fetch.status == 200, "network.get \(fetch.status) \(fetch.error)")
            report.check(fetch.body.contains("AppRuntime"), "network.get sent the header")
            report.check(fetch.mimeType == "application/json", "network.response mimeType \(fetch.mimeType ?? "-")")
        }
    }

    private func redirect() {
        let url = "https://httpbin.org/redirect-to?url=https%3A%2F%2Fhttpbin.org%2Fget&status_code=302"
        let task = fetch(url) { [report] fetch in
            report.check(fetch.error == 0 && fetch.status == 200 && fetch.redirects == [302], "network.redirect \(fetch.redirects.map { String($0) }.joined(separator: " "))")
        }
        _ = task
    }

    private func upload() {
        let body = [UInt8](repeating: 97, count: 100_000)
        _ = fetch("https://httpbin.org/post", method: "POST", body: body) { [report] fetch in
            report.check(fetch.error == 0 && fetch.status == 200, "network.upload \(fetch.status) \(fetch.error)")
            report.check(fetch.sent == 100_000, "network.upload progress \(fetch.sent)")
        }
    }

    private func authenticate() {
        _ = fetch("https://httpbin.org/basic-auth/ada/secret") { [report] fetch in
            report.check(fetch.challenges == 1 && fetch.status == 200, "network.challenge \(fetch.challenges) \(fetch.status)")
        }
        current?.credential = HTTPCredentialProxy.make(user: "ada", password: "secret", persistence: HTTPCredentialPersistence.none.rawValue)
    }

    private func notFound() {
        _ = fetch("https://httpbin.org/status/404") { [report] fetch in
            report.check(fetch.error == 0 && fetch.status == 404, "network.status 404 \(fetch.status)")
        }
    }

    private func unknownHost() {
        _ = fetch("https://appruntime-check.invalid/") { [report] fetch in
            report.check(fetch.error == NetworkError.cannotFindHost.rawValue, "network.cannotFindHost \(fetch.error)")
        }
    }

    private func cleartext() {
        _ = fetch("http://example.com/") { [report] fetch in
            report.check(fetch.error == NetworkError.insecureConnectionNotAllowed.rawValue, "network.insecureConnectionNotAllowed \(fetch.error)")
        }
    }

    private func cancel() {
        let task = fetch("https://httpbin.org/delay/5") { [report] fetch in
            report.check(fetch.error == NetworkError.cancelled.rawValue, "network.cancel \(fetch.error)")
        }
        task?.cancel()
    }
}

/// One request's events.
final class Fetch: HTTPTaskDelegate {

    let finished: (Fetch) -> Void

    var status: Int32 = -1
    var mimeType: String?
    var body: [UInt8] = []
    var redirects: [Int32] = []
    var challenges = 0
    var credential: HTTPCredential?
    var sent: Int64 = 0
    var error: Int32 = -1

    init(_ finished: @escaping (Fetch) -> Void) {
        self.finished = finished
    }

    func willPerformRedirect(_ task: HTTPTask, response: HTTPResponse, newRequest: HTTPRequest) -> Bool {
        redirects.append(response.statusCode())
        return true
    }

    func didReceiveChallenge(_ task: HTTPTask, method: Int32, host: String, realm: String?, previousFailureCount: Int32) -> HTTPCredential? {
        challenges += 1
        return previousFailureCount == 0 ? credential : nil
    }

    func didReceiveResponse(_ task: HTTPTask, response: HTTPResponse) -> Bool {
        status = response.statusCode()
        mimeType = response.mimeType()
        return true
    }

    func didReceiveData(_ task: HTTPTask, data: [UInt8]) {
        body += data
    }

    func didSendBodyData(_ task: HTTPTask, bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        sent = totalBytesSent
    }

    func taskIsWaitingForConnectivity(_ task: HTTPTask) {}

    func didComplete(_ task: HTTPTask, error: Int32, message: String?) {
        self.error = error
        finished(self)
    }
}

extension Array where Element == UInt8 {

    /// Whether the bytes contain `text`'s UTF-8.
    func contains(_ text: String) -> Bool {
        let needle = Array(text.utf8)
        guard !needle.isEmpty, needle.count <= count else { return needle.isEmpty }
        for start in 0...(count - needle.count) where self[start] == needle[0] {
            if Array(self[start..<start + needle.count]) == needle {
                return true
            }
        }
        return false
    }
}
