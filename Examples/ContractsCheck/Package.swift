// swift-tools-version:6.4
import Foundation
import PackageDescription

/// A guest app that calls each contract this host implements and shows
/// what came back, one `ok` or `FAIL` line per check
/// (`Scripts/contracts-check.sh` builds and drives it).
///
/// `APPRUNTIME_PATH` points at the AppRuntime checkout; `../AppRuntime`
/// next to this repository by default.
let appRuntime = ProcessInfo.processInfo.environment["APPRUNTIME_PATH"]
    ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../AppRuntime").standardized.path

func runtime(_ product: String) -> Target.Dependency {
    .product(name: product, package: "AppRuntime")
}

let package = Package(
    name: "ContractsCheck",
    products: [
        .library(name: "ContractsCheck", type: .static, targets: ["ContractsCheck"]),
    ],
    dependencies: [
        .package(name: "AppRuntime", path: appRuntime),
    ],
    targets: [
        .target(
            name: "ContractsCheck",
            dependencies: [
                runtime("DynamicRuntime"), runtime("DynamicSwiftUI"),
                runtime("DynamicDevice"), runtime("DynamicFormatting"),
                runtime("DynamicLocation"), runtime("DynamicNetworking"),
                runtime("DynamicBluetooth"), runtime("DynamicMotion"), runtime("DynamicNFC"),
            ]
        ),
    ]
)
