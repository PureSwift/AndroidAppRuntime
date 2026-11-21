import AndroidHost
import AndroidHostAuthentication
import AndroidHostSecrets
import SwiftJava

/// The Kotlin `SecretSystem` (`:appruntime-contracts`). Made on the main
/// thread, where its class can be found; called on the secrets queue.
@JavaClass("org.pureswift.appruntime.contracts.SecretSystem")
open class JavaSecretSystem: JavaObject {

    @JavaMethod
    @_nonoverride public convenience init(environment: JNIEnvironment? = nil)

    @JavaMethod open func error() -> Int32
    @JavaMethod open func found() -> Bool
    @JavaMethod open func set(_ key: String, _ value: [Int8])
    @JavaMethod open func value(_ key: String) -> [Int8]
    @JavaMethod open func remove(_ key: String)
    @JavaMethod open func removeAll()
    @JavaMethod open func keys() -> [String]
}

extension JavaSecretSystem: SecretSystem {

    public func set(_ key: String, value: [UInt8]) {
        set(key, value.map { Int8(bitPattern: $0) })
    }

    public func value(_ key: String) -> [UInt8] {
        let bytes: [Int8] = value(key)
        return bytes.map { UInt8(bitPattern: $0) }
    }
}

/// The Kotlin `AuthenticationSystem` (`:appruntime-contracts`).
@JavaClass("org.pureswift.appruntime.contracts.AuthenticationSystem")
open class JavaAuthenticationSystem: JavaObject {

    @JavaMethod
    @_nonoverride public convenience init(environment: JNIEnvironment? = nil)

    @JavaMethod open func present(_ url: String, _ ephemeral: Bool) -> Bool
    @JavaMethod open func close()
}

extension JavaAuthenticationSystem: AuthenticationSystem {

    public func present(_ url: String, ephemeral: Bool) -> Bool {
        present(url, ephemeral)
    }
}

/// The Kotlin `AuthenticationNatives` object: a redirect to the app's scheme.
@JavaClass("org.pureswift.appruntime.contracts.AuthenticationNatives")
open class AuthenticationNatives: JavaObject {}

@JavaImplementation("org.pureswift.appruntime.contracts.AuthenticationNatives")
extension AuthenticationNatives {

    @JavaMethod
    public func redirected(_ url: String) {
        AndroidHostAuthentication.presenter?.redirected(url)
    }
}
