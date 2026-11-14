import AndroidHost
import SwiftJava

/// The Kotlin `PermissionSystem` (`:appruntime-contracts`).
@JavaClass("org.pureswift.appruntime.contracts.PermissionSystem")
open class JavaPermissionSystem: JavaObject {

    @JavaMethod
    @_nonoverride public convenience init(environment: JNIEnvironment? = nil)

    @JavaMethod open func apiLevel() -> Int32
    @JavaMethod open func isGranted(_ permission: String) -> Bool
    @JavaMethod open func wasRequested(_ permission: String) -> Bool
    @JavaMethod open func isDeclared(_ permission: String) -> Bool
    @JavaMethod open func hasFeature(_ feature: String) -> Bool
    @JavaMethod open func request(_ permissions: [String], _ id: Int32) -> Bool
}

/// `AndroidPermissions`' system over the Kotlin class.
final class AndroidPermissionSystem: PermissionSystem {

    let java = JavaPermissionSystem()

    lazy var apiLevel: Int32 = java.apiLevel()

    func isGranted(_ permission: String) -> Bool {
        java.isGranted(permission)
    }

    func wasRequested(_ permission: String) -> Bool {
        java.wasRequested(permission)
    }

    func isDeclared(_ permission: String) -> Bool {
        java.isDeclared(permission)
    }

    func hasFeature(_ feature: String) -> Bool {
        java.hasFeature(feature)
    }

    func request(_ permissions: [String], id: Int32) -> Bool {
        java.request(permissions, id)
    }
}

/// The Kotlin `PermissionNatives` object: the Activity's
/// `onRequestPermissionsResult`.
@JavaClass("org.pureswift.appruntime.contracts.PermissionNatives")
open class PermissionNatives: JavaObject {}

@JavaImplementation("org.pureswift.appruntime.contracts.PermissionNatives")
extension PermissionNatives {

    @JavaMethod
    public func result(_ id: Int32, _ permissions: [String], _ granted: [Bool]) {
        AndroidPermissions.didRequest(id: id, permissions: permissions, granted: granted)
    }
}
