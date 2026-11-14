import AndroidHostNetworking
import SwiftJava

/// The Kotlin `NetworkSystem` (`:appruntime-contracts`).
@JavaClass("org.pureswift.appruntime.contracts.NetworkSystem")
open class JavaNetworkSystem: JavaObject {

    @JavaMethod
    @_nonoverride public convenience init(environment: JNIEnvironment? = nil)

    @JavaMethod open func makeSession(_ ephemeral: Bool, _ cookies: Bool, _ connections: Int32) -> JavaHTTPSession!
    @JavaMethod open func networkState() -> [Int32]
    @JavaMethod open func setConnectivityListening(_ on: Bool)
}

@JavaClass("org.pureswift.appruntime.contracts.HttpSession")
open class JavaHTTPSession: JavaObject {

    @JavaMethod
    open func start(_ handle: Int64, _ url: String, _ method: String, _ headerNames: [String], _ headerValues: [String],
                    _ body: [UInt8], _ hasBody: Bool, _ upload: Bool, _ timeout: Int32, _ useCaches: Bool,
                    _ cacheControl: String) -> JavaHTTPCall!

    @JavaMethod open func removeAllCookies()
    @JavaMethod open func removeAllCachedResponses()
    @JavaMethod open func close()
}

@JavaClass("org.pureswift.appruntime.contracts.HttpCall")
open class JavaHTTPCall: JavaObject {
    @JavaMethod open func cancel()
}

extension JavaHTTPCall: NetworkCall {}

/// `AndroidHostNetworking`'s system over the Kotlin class.
final class AndroidNetworkSystem: NetworkSystem {

    let java = JavaNetworkSystem()

    func makeSession(_ configuration: SessionSpec) -> any NetworkSessionSource {
        SessionAdapter(java.makeSession(configuration.ephemeral, configuration.shouldSetCookies, configuration.maximumConnections))
    }

    func networkState() -> NetworkState {
        let values = java.networkState()
        guard values.count == 4 else { return NetworkState(isConnected: true) }
        return NetworkState(isConnected: values[0] == 1, isCellular: values[1] == 1, isMetered: values[2] == 1,
                            isDataSaver: values[3] == 1)
    }

    func setConnectivityListening(_ on: Bool) {
        java.setConnectivityListening(on)
    }

    final class SessionAdapter: NetworkSessionSource {

        let java: JavaHTTPSession

        init(_ java: JavaHTTPSession) {
            self.java = java
        }

        func start(_ task: TaskSpec, handle: Int64) -> any NetworkCall {
            java.start(handle, task.url, task.method, task.headers.map(\.0), task.headers.map(\.1), task.body ?? [],
                       task.body != nil, task.isUpload, task.timeout, task.useCaches, task.cacheControl ?? "")
        }

        func removeAllCookies() {
            java.removeAllCookies()
        }

        func removeAllCachedResponses() {
            java.removeAllCachedResponses()
        }

        func close() {
            java.close()
        }
    }
}

/// The Kotlin `NetworkNatives` object: what the session threads report.
@JavaClass("org.pureswift.appruntime.contracts.NetworkNatives")
open class NetworkNatives: JavaObject {}

@JavaImplementation("org.pureswift.appruntime.contracts.NetworkNatives")
extension NetworkNatives {

    @JavaMethod
    public func connectivityChanged() {
        NetworkHub.shared.connectivityChanged()
    }

    @JavaMethod
    public func redirect(_ handle: Int64, _ status: Int32, _ names: [String], _ values: [String], _ url: String) -> String {
        NetworkHub.shared.redirect(handle: handle, status: status, headers: Array(zip(names, values)), url: url)
    }

    @JavaMethod
    public func challenge(_ handle: Int64, _ header: String, _ proxy: Bool, _ host: String, _ previousFailureCount: Int32) -> [String] {
        NetworkHub.shared.challenge(handle: handle, header: header, proxy: proxy, host: host, previousFailureCount: previousFailureCount)
    }

    @JavaMethod
    public func response(_ handle: Int64, _ status: Int32, _ names: [String], _ values: [String], _ url: String) {
        NetworkHub.shared.response(handle: handle, status: status, headers: Array(zip(names, values)), url: url)
    }

    @JavaMethod
    public func data(_ handle: Int64, _ bytes: [UInt8]) {
        NetworkHub.shared.data(handle: handle, bytes)
    }

    @JavaMethod
    public func sent(_ handle: Int64, _ bytes: Int64, _ total: Int64, _ expected: Int64) {
        NetworkHub.shared.sent(handle: handle, bytes: bytes, total: total, expected: expected)
    }

    @JavaMethod
    public func complete(_ handle: Int64, _ exception: String, _ message: String) {
        NetworkHub.shared.complete(handle: handle, exception: exception, message: message)
    }
}
