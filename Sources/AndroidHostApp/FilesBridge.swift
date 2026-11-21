import AndroidHost
import AndroidHostFiles
import CAndroidHost
import SwiftJava

/// The Kotlin `FileSystem` (`:appruntime-contracts`).
@JavaClass("org.pureswift.appruntime.contracts.FileSystem")
open class JavaFileSystem: JavaObject {

    @JavaMethod
    @_nonoverride public convenience init(environment: JNIEnvironment? = nil)

    @JavaMethod open func filesDirectory() -> String

    @JavaMethod open func cacheDirectory() -> String

    @JavaMethod open func databaseDirectory() -> String

    @JavaMethod open func assets() -> JavaAssetManager!
}

@JavaClass("android.content.res.AssetManager")
open class JavaAssetManager: JavaObject {}

enum FilesBridge {

    /// The Java `AssetManager` the NDK's reads go through, kept for as long
    /// as the app runs.
    nonisolated(unsafe) static var assetManager: JavaAssetManager?

    /// Points `AndroidFiles` at the app's directories and its assets, before
    /// the app starts. If that fails, the app runs without files.
    static func configure() {
        let system = JavaFileSystem()
        var assets: (any AssetReader)?
        #if os(Android)
        if let manager = system.assets(),
           let native = candroid_assets_from_java(UnsafeMutableRawPointer(manager.javaEnvironment),
                                                  UnsafeMutableRawPointer(manager.javaThis)) {
            assetManager = manager
            assets = NDKAssets(manager: native)
        } else {
            HostLog.error("Files: the APK's assets can't be read; the bundle is empty")
        }
        #endif
        let directories = AndroidFiles.Configuration.directories(files: system.filesDirectory(), cache: system.cacheDirectory())
        do {
            try AndroidFiles.configure(AndroidFiles.Configuration(directories: directories, assets: assets))
        } catch {
            HostLog.error("Files: the app's directories can't be made: error \(error.rawValue)")
        }
    }
}
