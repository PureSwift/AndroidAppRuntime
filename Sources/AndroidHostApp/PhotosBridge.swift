import AndroidHost
import AndroidHostPhotos
import SwiftJava

/// The Kotlin `PhotoSystem` (`:appruntime-contracts`): `MediaStore`.
@JavaClass("org.pureswift.appruntime.contracts.PhotoSystem")
open class JavaPhotoSystem: JavaObject {

    @JavaMethod
    @_nonoverride public convenience init(environment: JNIEnvironment? = nil)

    @JavaMethod open func error() -> Int32
    @JavaMethod open func identifiers(_ kind: Int32, _ album: String) -> [String]
    @JavaMethod open func assets(_ identifiers: [String]) -> [String]
    @JavaMethod open func albums() -> [String]
    @JavaMethod open func add(_ path: String, _ kind: Int32) -> [String]
    @JavaMethod open func original(_ identifier: String) -> [String]
    @JavaMethod open func release(_ path: String)
    @JavaMethod open func delete(_ identifiers: [String], _ request: Int32)
    @JavaMethod open func observe()
}

extension JavaPhotoSystem: PhotoSystem {

    public func identifiers(_ kind: Int32, album: String) -> [String] { identifiers(kind, album) }
    public func add(_ path: String, kind: Int32) -> [String] { add(path, kind) }
    public func delete(_ identifiers: [String], request: Int32) { delete(identifiers, request) }
}

/// What the library reports, on the main thread.
@JavaClass("org.pureswift.appruntime.contracts.PhotoNatives")
open class PhotoNatives: JavaObject {}

@JavaImplementation("org.pureswift.appruntime.contracts.PhotoNatives")
extension PhotoNatives {

    @JavaMethod
    public func changed() {
        PhotoHub.shared.changed()
    }

    @JavaMethod
    public func deleted(_ request: Int32, _ error: Int32) {
        PhotoHub.shared.deleted(request, error: error)
    }
}
