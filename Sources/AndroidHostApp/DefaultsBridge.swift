import AndroidHostDefaults
import SwiftJava

/// The Kotlin `DefaultsSystem` (`:appruntime-contracts`).
@JavaClass("org.pureswift.appruntime.contracts.DefaultsSystem")
open class JavaDefaultsSystem: JavaObject {

    @JavaMethod
    @_nonoverride public convenience init(environment: JNIEnvironment? = nil)

    @JavaMethod open func contains(_ key: String) -> Bool

    @JavaMethod open func string(_ key: String) -> String

    @JavaMethod open func set(_ key: String, _ value: String, _ removing: String)

    @JavaMethod open func remove(_ keys: [String])

    @JavaMethod open func keys() -> [String]
}

extension JavaDefaultsSystem: PreferencesSystem {

    public func set(_ key: String, value: String, removing: String) {
        set(key, value, removing)
    }
}
