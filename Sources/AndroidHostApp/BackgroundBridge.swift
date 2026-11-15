import AndroidHost
import SwiftJava

/// The Kotlin `BackgroundSystem` (`:appruntime-contracts`).
@JavaClass("org.pureswift.appruntime.contracts.BackgroundSystem")
open class JavaBackgroundSystem: JavaObject {

    @JavaMethod
    @_nonoverride public convenience init(environment: JNIEnvironment? = nil)

    @JavaMethod open func run(_ types: Int32) -> Int32
}

extension JavaBackgroundSystem: BackgroundSystem {

    public func run(types: Int32) -> Int32 {
        run(types)
    }
}
