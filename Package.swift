// swift-tools-version:6.4
import Foundation
import PackageDescription

/// The Android host for AppRuntime apps (`Documentation/Plan.md`).
///
/// Built with Swift 6.4 and the Swift SDK for Android:
///
///     swift build --swift-sdk swift-6.4.2-RELEASE_android --triple aarch64-unknown-linux-android28
///
/// AppRuntime comes without its `GuestExports` trait: the app's library, a
/// sealed slice or wasm2c output, defines `rt_dispatch` and `rt_finalize`,
/// and the host's own `DynamicRuntime` binds to the runtime directly.
///
/// `APPRUNTIME_PATH` points at a local AppRuntime checkout instead of
/// GitHub, for developing both at once.
let appRuntime: Package.Dependency = {
    if let path = ProcessInfo.processInfo.environment["APPRUNTIME_PATH"] {
        return .package(name: "AppRuntime", path: path, traits: [])
    }
    return .package(url: "https://github.com/PureSwift/AppRuntime.git", branch: "master", traits: [])
}()

func runtime(_ product: String) -> Target.Dependency {
    .product(name: product, package: "AppRuntime")
}

/// The app's library for `ExampleAppHost`: the sealed `libapp.a` for the ABI
/// being built (`Scripts/example-app.sh` sets it). It defines `rt_main`,
/// `rt_dispatch` and `rt_finalize`.
///
/// Linker flags live here, limited to Android, because Swift 6.4's build
/// system also passes `-Xlinker`, `-Xswiftc` and `--static-swift-stdlib` to
/// the macOS builds of the package's macros.
let slice = ProcessInfo.processInfo.environment["ANDROIDAPPRUNTIME_SLICE"]

/// The Swift SDK for Android's toolset already links with
/// `-z max-page-size=16384`: Google Play requires 16 KB pages for apps
/// targeting API 35.
let androidLinking: [LinkerSetting] = []

/// Host code is single-threaded on the main thread (§6.4), and swift-java's
/// macros generate Swift 5 code, so host targets use the Swift 5 language
/// mode, like the other hosts.
let host: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "AndroidAppRuntime",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        // Phase 0: AppRuntime's ExampleApp, linked from its sealed Android
        // slice and run from a bare Activity (`Scripts/example-app.sh`).
        .library(name: "ExampleAppHost", type: .dynamic, targets: ["ExampleAppHost"]),
    ],
    dependencies: [
        appRuntime,
        .package(url: "https://github.com/swiftlang/swift-java.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "ExampleAppHost",
            dependencies: [
                runtime("CRuntime"), runtime("RuntimeCore"), runtime("RuntimeNative"),
                runtime("DynamicRuntime"), runtime("ExampleContracts"), runtime("ExampleHost"),
                .product(name: "SwiftJavaStatic", package: "swift-java"),
            ],
            swiftSettings: host,
            linkerSettings: androidLinking + (slice.map { [.unsafeFlags([$0], .when(platforms: [.android]))] } ?? [])
        ),
    ]
)
