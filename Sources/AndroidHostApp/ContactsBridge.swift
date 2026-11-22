import AndroidHost
import AndroidHostContacts
import SwiftJava

/// The Kotlin `ContactSystem` (`:appruntime-contracts`). Made on the main
/// thread, where its class can be found; called on the contacts queue,
/// and `observe` on the main thread.
@JavaClass("org.pureswift.appruntime.contracts.ContactSystem")
open class JavaContactSystem: JavaObject {

    @JavaMethod
    @_nonoverride public convenience init(environment: JNIEnvironment? = nil)

    @JavaMethod open func error() -> Int32
    @JavaMethod open func all() -> [String]
    @JavaMethod open func search(_ text: String, _ limit: Int32) -> [String]
    @JavaMethod open func find(_ identifier: String) -> [String]
    @JavaMethod open func save(_ fields: [String]) -> String
    @JavaMethod open func remove(_ identifier: String)
    @JavaMethod open func observe()
}

extension JavaContactSystem: ContactSystem {

    public func search(_ text: String, limit: Int32) -> [String] {
        search(text, limit)
    }
}

/// The Kotlin `ContactNatives` object: the store's changes.
@JavaClass("org.pureswift.appruntime.contracts.ContactNatives")
open class ContactNatives: JavaObject {}

@JavaImplementation("org.pureswift.appruntime.contracts.ContactNatives")
extension ContactNatives {

    @JavaMethod
    public func changed() {
        AndroidHostContacts.changed()
    }
}

/// The contacts module's Kotlin side.
enum ContactsBridge {

    /// `allowsWriting`: the manifest's contacts access isn't `readOnly`.
    static func configure(allowsWriting: Bool) {
        let java = JavaContactSystem()
        AndroidHostContacts.configure(AndroidContactDirectory(system: java), allowsWriting: allowsWriting) {
            java.observe()
        }
    }
}
