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

/// The app's library for `app` and `ExampleAppHost`: the sealed `libapp.a`
/// for the ABI being built (the scripts set it). It defines `rt_main`,
/// `rt_dispatch` and `rt_finalize`.
///
/// Linker flags live here, limited to Android, because Swift 6.4's build
/// system also passes `-Xlinker`, `-Xswiftc` and `--static-swift-stdlib` to
/// the macOS builds of the package's macros.
let slice = ProcessInfo.processInfo.environment["ANDROIDAPPRUNTIME_SLICE"].flatMap { $0.isEmpty ? nil : $0 }

/// Elsewhere there's no slice: the libraries that link one are only for
/// Android, and leave its symbols undefined so `swift test` builds on macOS.
let sliceLinking: [LinkerSetting] = (slice.map { [.unsafeFlags([$0], .when(platforms: [.android]))] } ?? [])
    + [.unsafeFlags(["-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"], .when(platforms: [.macOS]))]

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
        // The host, with the app's slice linked in: the shell loads
        // `libapp.so` (§4).
        .library(name: "app", type: .dynamic, targets: ["AndroidHostApp"]),
        .library(name: "AndroidHost", targets: ["AndroidHost"]),
        .library(name: "AndroidHostUI", targets: ["AndroidHostUI"]),
        .library(name: "AndroidHostDevice", targets: ["AndroidHostDevice"]),
        .library(name: "AndroidHostFormatting", targets: ["AndroidHostFormatting"]),
        .library(name: "AndroidHostLocation", targets: ["AndroidHostLocation"]),
        .library(name: "AndroidHostNetworking", targets: ["AndroidHostNetworking"]),
        .library(name: "AndroidHostBluetooth", targets: ["AndroidHostBluetooth"]),
        .library(name: "AndroidHostMotion", targets: ["AndroidHostMotion"]),
        .library(name: "AndroidHostNFC", targets: ["AndroidHostNFC"]),
        .library(name: "AndroidHostGraphics", targets: ["AndroidHostGraphics"]),
        .library(name: "AndroidHostWebKit", targets: ["AndroidHostWebKit"]),
        .library(name: "AndroidHostFiles", targets: ["AndroidHostFiles"]),
        .library(name: "AndroidHostDefaults", targets: ["AndroidHostDefaults"]),
        .library(name: "AndroidHostModelStore", targets: ["AndroidHostModelStore"]),
        .library(name: "AndroidHostDocuments", targets: ["AndroidHostDocuments"]),
        .library(name: "AndroidHostMedia", targets: ["AndroidHostMedia"]),
        // The packager, which runs on the build machine (§8).
        .library(name: "AndroidPackager", targets: ["AndroidPackager"]),
        .executable(name: "android-app", targets: ["AndroidAppTool"]),
        // Phase 0: AppRuntime's ExampleApp, linked from its sealed Android
        // slice and run from a bare Activity (`Scripts/example-app.sh`).
        .library(name: "ExampleAppHost", type: .dynamic, targets: ["ExampleAppHost"]),
    ],
    dependencies: [
        appRuntime,
        .package(url: "https://github.com/swiftlang/swift-java.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        // The model store's backend (§6.7). SQLite from 0.2.3 nests a
        // transaction in another, which makes a batch all or nothing.
        .package(url: "https://github.com/PureSwift/CoreModel.git", from: "2.11.1"),
        .package(url: "https://github.com/PureSwift/CoreModel-SQLite.git", from: "0.3.3"),
        .package(url: "https://github.com/PureSwift/SQLite.git", from: "0.2.3"),
    ],
    targets: [
        .target(
            name: "CAndroidHost",
            linkerSettings: [
                .linkedLibrary("android", .when(platforms: [.android])),
                .linkedLibrary("log", .when(platforms: [.android])),
                .linkedLibrary("EGL", .when(platforms: [.android])),
                // A slice that draws calls GLES 2.0 itself (§6.3).
                .linkedLibrary("GLESv2", .when(platforms: [.android])),
            ]
        ),
        .target(
            name: "AndroidHost",
            dependencies: [
                "CAndroidHost",
                runtime("RuntimeABI"), runtime("RuntimeCore"), runtime("RuntimeNative"),
                runtime("DynamicRuntime"), runtime("RuntimeHost"),
            ],
            swiftSettings: host
        ),
        .target(
            name: "AndroidHostUI",
            dependencies: ["AndroidHost", runtime("DynamicUI")],
            swiftSettings: host
        ),
        .target(
            name: "AndroidHostDevice",
            dependencies: ["AndroidHost", runtime("DynamicDevice")],
            swiftSettings: host
        ),
        .target(
            name: "AndroidHostFormatting",
            dependencies: ["AndroidHost", runtime("DynamicFormatting")],
            swiftSettings: host
        ),
        .target(
            name: "AndroidHostLocation",
            dependencies: ["AndroidHost", runtime("DynamicLocation")],
            swiftSettings: host
        ),
        .target(
            name: "AndroidHostNetworking",
            dependencies: ["AndroidHost", runtime("DynamicNetworking")],
            swiftSettings: host
        ),
        .target(
            name: "AndroidHostBluetooth",
            dependencies: ["AndroidHost", runtime("DynamicBluetooth")],
            swiftSettings: host
        ),
        .target(
            name: "AndroidHostMotion",
            dependencies: ["AndroidHost", "CAndroidHost", runtime("DynamicMotion")],
            swiftSettings: host
        ),
        .target(
            name: "AndroidHostNFC",
            dependencies: ["AndroidHost", runtime("DynamicNFC")],
            swiftSettings: host
        ),
        .target(
            name: "AndroidHostGraphics",
            dependencies: ["AndroidHost", "CAndroidHost", runtime("DynamicGraphics")],
            swiftSettings: host
        ),
        .target(
            name: "AndroidHostWebKit",
            dependencies: ["AndroidHost", runtime("DynamicWebKit")],
            swiftSettings: host
        ),
        .target(
            name: "AndroidHostFiles",
            dependencies: ["AndroidHost", "CAndroidHost", runtime("DynamicFiles"), runtime("RuntimeHost")],
            swiftSettings: host
        ),
        .target(
            name: "AndroidHostDefaults",
            dependencies: [runtime("DynamicDefaults"), runtime("DynamicRuntime"), runtime("RuntimeHost")],
            swiftSettings: host
        ),
        .target(
            name: "AndroidHostModelStore",
            dependencies: [
                runtime("DynamicCoreModel"), runtime("RuntimeCoreModel"), runtime("DynamicRuntime"), runtime("RuntimeHost"),
                .product(name: "CoreModel", package: "CoreModel"),
                .product(name: "CoreModelSQLite", package: "CoreModel-SQLite"),
                .product(name: "SQLite", package: "SQLite"),
            ],
            swiftSettings: host
        ),
        .target(
            name: "AndroidHostDocuments",
            dependencies: [
                "AndroidHost", "AndroidHostFiles", runtime("DynamicDocuments"), runtime("DynamicFiles"),
                runtime("DynamicRuntime"), runtime("RuntimeHost"),
            ],
            swiftSettings: host
        ),
        .target(
            name: "AndroidHostMedia",
            dependencies: [
                "AndroidHost", "AndroidHostFiles", runtime("DynamicFiles"), runtime("DynamicMedia"),
                runtime("RuntimeMedia"), runtime("DynamicRuntime"), runtime("RuntimeHost"), runtime("RuntimeCore"),
            ],
            swiftSettings: host
        ),
        .target(
            name: "AndroidHostModules",
            dependencies: [
                "AndroidHost", "AndroidHostUI", "AndroidHostDevice", "AndroidHostFormatting", "AndroidHostLocation",
                "AndroidHostNetworking", "AndroidHostBluetooth", "AndroidHostMotion", "AndroidHostNFC",
                "AndroidHostGraphics", "AndroidHostWebKit", "AndroidHostFiles",
                "AndroidHostDefaults", "AndroidHostModelStore", "AndroidHostDocuments", "AndroidHostMedia",
            ],
            swiftSettings: host
        ),
        .target(
            name: "AndroidHostApp",
            dependencies: [
                "AndroidHostModules", "AndroidHost", "AndroidHostUI", "AndroidHostDevice", "AndroidHostFormatting",
                "AndroidHostLocation", "AndroidHostNetworking", "AndroidHostBluetooth", "AndroidHostMotion",
                "AndroidHostNFC", "AndroidHostGraphics", "AndroidHostWebKit", "AndroidHostFiles", "AndroidHostDefaults",
                "AndroidHostModelStore", "AndroidHostDocuments", "AndroidHostMedia", runtime("CRuntime"),
                .product(name: "SwiftJavaStatic", package: "swift-java"),
            ],
            swiftSettings: host,
            linkerSettings: androidLinking + sliceLinking
        ),
        .target(
            name: "AndroidPackager",
            dependencies: [
                "AndroidHostModules", "AndroidHostFiles", runtime("RuntimeABI"), runtime("RuntimeHost"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .executableTarget(
            name: "AndroidAppTool",
            dependencies: ["AndroidPackager", .product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        .testTarget(
            name: "AndroidPackagerTests",
            dependencies: ["AndroidPackager"]
        ),
        .testTarget(
            name: "AndroidHostTests",
            dependencies: ["AndroidHost"],
            swiftSettings: host
        ),
        .testTarget(
            name: "AndroidHostUITests",
            dependencies: ["AndroidHostUI"],
            swiftSettings: host
        ),
        .testTarget(
            name: "AndroidHostFormattingTests",
            dependencies: ["AndroidHostFormatting"],
            swiftSettings: host
        ),
        .testTarget(
            name: "AndroidHostLocationTests",
            dependencies: ["AndroidHostLocation"],
            swiftSettings: host
        ),
        .testTarget(
            name: "AndroidHostNetworkingTests",
            dependencies: ["AndroidHostNetworking"],
            swiftSettings: host
        ),
        .testTarget(
            name: "AndroidHostBluetoothTests",
            dependencies: ["AndroidHostBluetooth"],
            swiftSettings: host
        ),
        .testTarget(
            name: "AndroidHostMotionTests",
            dependencies: ["AndroidHostMotion"],
            swiftSettings: host
        ),
        .testTarget(
            name: "AndroidHostNFCTests",
            dependencies: ["AndroidHostNFC"],
            swiftSettings: host
        ),
        .testTarget(
            name: "AndroidHostGraphicsTests",
            dependencies: ["AndroidHostGraphics"],
            swiftSettings: host
        ),
        .testTarget(
            name: "AndroidHostWebKitTests",
            dependencies: ["AndroidHostWebKit"],
            swiftSettings: host
        ),
        .testTarget(
            name: "AndroidHostFilesTests",
            dependencies: ["AndroidHostFiles"],
            swiftSettings: host
        ),
        .testTarget(
            name: "AndroidHostDocumentsTests",
            dependencies: ["AndroidHostDocuments", "AndroidHostFiles", runtime("DynamicDocuments"), runtime("DynamicFiles")],
            swiftSettings: host
        ),
        .testTarget(
            name: "AndroidHostMediaTests",
            dependencies: [
                "AndroidHostMedia", "AndroidHostFiles", runtime("DynamicMedia"), runtime("RuntimeMedia"),
                runtime("DynamicFiles"), runtime("RuntimeHost"), runtime("RuntimeNative"),
            ],
            swiftSettings: host
        ),
        .testTarget(
            name: "AndroidHostDefaultsTests",
            dependencies: ["AndroidHostDefaults"],
            swiftSettings: host
        ),
        .testTarget(
            name: "AndroidHostModelStoreTests",
            dependencies: [
                "AndroidHostModelStore", runtime("DynamicCoreModel"), runtime("RuntimeCoreModel"), runtime("RuntimeNative"),
                .product(name: "CoreModel", package: "CoreModel"),
                .product(name: "SQLite", package: "SQLite"),
            ],
            swiftSettings: host
        ),
        .testTarget(
            name: "AndroidHostDeviceTests",
            dependencies: ["AndroidHostDevice"],
            swiftSettings: host
        ),
        .target(
            name: "ExampleAppHost",
            dependencies: [
                runtime("CRuntime"), runtime("RuntimeCore"), runtime("RuntimeNative"),
                runtime("DynamicRuntime"), runtime("ExampleContracts"), runtime("ExampleHost"),
                .product(name: "SwiftJavaStatic", package: "swift-java"),
            ],
            swiftSettings: host,
            linkerSettings: androidLinking + sliceLinking
        ),
    ]
)
