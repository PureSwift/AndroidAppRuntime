@testable import AndroidPackager
import Foundation
import Testing

/// The manifest, the Gradle project, staging the libraries, and the steps
/// `package` and `run` take.
@Suite struct ProjectTests {

    let directory = TemporaryDirectory()

    func bundle(_ info: [String: Any] = Fixtures.info(), icon: Bool = false, names: [String: String] = [:]) throws -> UniversalBundle {
        try UniversalBundle(url: Fixtures.bundle(in: directory, info: info, icon: icon, names: names))
    }

    func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: Manifest

    @Test func asksForEachCapabilitysPermissions() throws {
        let info = Fixtures.info([
            "RTCapabilities": ["bluetooth", "location", "network"],
            "RTCapabilityOptions": ["location": ["access": "always"], "bluetooth": ["required": "true"]],
        ])
        let writer = ManifestWriter(bundle: try bundle(info))
        let names = writer.permissions.map(\.name)
        #expect(names == [
            "android.permission.ACCESS_FINE_LOCATION", "android.permission.ACCESS_COARSE_LOCATION",
            "android.permission.ACCESS_BACKGROUND_LOCATION", "android.permission.BLUETOOTH_SCAN",
            "android.permission.BLUETOOTH_CONNECT", "android.permission.BLUETOOTH", "android.permission.BLUETOOTH_ADMIN",
            "android.permission.INTERNET", "android.permission.ACCESS_NETWORK_STATE",
        ])
        // Location for every API, since the app uses it; not only to scan.
        #expect(writer.permissions.first { $0.name == "android.permission.ACCESS_FINE_LOCATION" }?.maxSDK == nil)
        #expect(writer.features == [
            .init(name: "android.hardware.bluetooth_le", required: true),
            .init(name: "android.hardware.location", required: false),
        ])
        let manifest = writer.manifest
        #expect(manifest.contains(#"<uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation" />"#))
        #expect(manifest.contains(#"<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />"#))
        #expect(manifest.contains(#"<uses-feature android:name="android.hardware.bluetooth_le" android:required="true" />"#))
        #expect(manifest.contains("org.pureswift.appruntime.AppRuntimeActivity"))
        #expect(manifest.contains(#"android:allowNativeHeapPointerTagging="false""#))
        #expect(!manifest.contains("android:icon"))
    }

    @Test func scansForBluetoothWithLocationOnOlderAPIsOnly() throws {
        let writer = ManifestWriter(bundle: try bundle(Fixtures.info(["RTCapabilities": ["bluetooth"]])))
        #expect(writer.permissions.first { $0.name == "android.permission.ACCESS_FINE_LOCATION" }?.maxSDK == 30)
    }

    @Test func mergesTheAppsExtraManifest() throws {
        let info = Fixtures.info(["RTPlatformExtras": ["android": ["extraManifest": "<queries>\n  <package android:name=\"a.b\" />\n</queries>"]]])
        let manifest = ManifestWriter(bundle: try bundle(info)).manifest
        #expect(manifest.contains("    <queries>\n      <package android:name=\"a.b\" />\n    </queries>"))
    }

    @Test func namesTheAppInEachLanguage() throws {
        let writer = ManifestWriter(bundle: try bundle(names: ["en": "Weather", "pt-BR": "Tempo", "zh-Hans": "天气"]))
        #expect(Set(writer.strings.keys) == ["values", "values-en", "values-pt-rBR", "values-b+zh+Hans"])
        #expect(writer.strings["values-pt-rBR"]?.contains("<string name=\"app_name\">Tempo</string>") == true)
        #expect(ManifestWriter.escapeString("Tom's <App> & @co") == "Tom\\'s &lt;App&gt; &amp; @co")
        #expect(ManifestWriter.escapeString("@home") == "\\@home")
        #expect(ManifestWriter.resourceQualifier("ES") == "es")
    }

    // MARK: Gradle project

    @Test func writesTheGradleProject() throws {
        let host = Fixtures.hostPackage(in: directory)
        let signing = GradleProject.Signing(keystore: URL(fileURLWithPath: "/keys/release.jks"), alias: "release")
        let project = GradleProject(directory: directory.url.appendingPathComponent("gradle"), hostPackage: host,
                                    bundle: try bundle(icon: true, names: ["en": "Weather", "es": "Tiempo"]),
                                    abis: [.arm64, .x86_64], signing: signing)
        try project.write()
        let root = project.directory
        let build = try read(root.appendingPathComponent("app/build.gradle.kts"))
        #expect(build.contains(#"applicationId = "org.example.Weather""#))
        #expect(build.contains("minSdk = 28"))
        #expect(build.contains("targetSdk = 35"))
        #expect(build.contains("versionCode = 7"))
        #expect(build.contains(#"versionName = "1.2""#))
        #expect(build.contains(#"abiFilters += listOf("arm64-v8a", "x86_64")"#))
        #expect(build.contains(#"storeFile = file("/keys/release.jks")"#))
        #expect(build.contains(#"System.getenv("ANDROID_KEYSTORE_PASSWORD")"#))
        #expect(build.contains("isMinifyEnabled = true"))
        let settings = try read(root.appendingPathComponent("settings.gradle.kts"))
        #expect(settings.contains(host.appendingPathComponent("Android/appruntime-shell").path))
        #expect(settings.contains(host.appendingPathComponent("Android/appruntime-contracts").path))
        for path in ["gradlew", "gradle/wrapper/gradle-wrapper.properties", "build.gradle.kts", "app/src/main/AndroidManifest.xml",
                     "app/src/main/res/values/strings.xml", "app/src/main/res/values-es/strings.xml",
                     "app/src/main/res/mipmap-xxxhdpi/ic_launcher.png", "app/src/main/assets/rt/Info.plist",
                     "app/src/main/assets/rt/resources/es.lproj/Manifest.strings"] {
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path), "\(path)")
        }
        #expect(try read(root.appendingPathComponent("app/src/main/AndroidManifest.xml")).contains(#"android:icon="@mipmap/ic_launcher""#))
    }

    @Test func rewritesResourcesTheAppDropped() throws {
        let host = Fixtures.hostPackage(in: directory)
        let url = directory.url.appendingPathComponent("gradle")
        try GradleProject(directory: url, hostPackage: host, bundle: try bundle(icon: true), abis: [.arm64]).write()
        try FileManager.default.removeItem(at: directory.url.appendingPathComponent("Weather.app/icon.png"))
        try GradleProject(directory: url, hostPackage: host, bundle: try bundle(), abis: [.arm64]).write()
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("app/src/main/res/mipmap-xxxhdpi").path))
    }

    @Test func refusesUnsignedReleases() throws {
        let project = GradleProject(directory: directory.url, hostPackage: directory.url, bundle: try bundle(), abis: [.arm64])
        let toolchain = Toolchain(androidHome: directory.url, ndk: directory.url, swiftSDKs: directory.url)
        #expect(throws: PackagerError("a release build needs a keystore: pass --keystore and --alias")) {
            try project.build(.bundle, androidSwiftUI: directory.url, toolchain: toolchain, runner: FakeRunner())
        }
    }

    // MARK: Staging and packaging

    /// A toolchain whose Swift SDK and NDK are in the temporary directory.
    func toolchain() -> Toolchain {
        let toolchain = Toolchain(androidHome: directory.url.appendingPathComponent("sdk"),
                                  ndk: directory.url.appendingPathComponent("ndk"),
                                  swiftSDKs: directory.url.appendingPathComponent("swift-sdks"))
        directory.write("", to: "ndk/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-readelf")
        for name in ["libswiftCore.so", "libFoundationEssentials.so", "libswift_Concurrency.so"] {
            let runtime = toolchain.swiftRuntime(.arm64).path.dropFirst(directory.url.path.count + 1)
            directory.write(name, to: "\(runtime)/\(name)")
        }
        let cxx = toolchain.libcxx(.arm64).path.dropFirst(directory.url.path.count + 1)
        directory.write("libc++", to: String(cxx))
        return toolchain
    }

    /// Answers `llvm-readelf -d` and `llvm-nm` like the NDK's tools.
    func libraryTools(missing: Bool = false) -> FakeRunner {
        let runner = FakeRunner()
        let needed = [
            "libapp.so": ["libswiftCore.so", "libFoundationEssentials.so", "liblog.so"],
            "libFoundationEssentials.so": ["libswiftCore.so", "libswift_Concurrency.so"],
            "libswiftCore.so": ["libc++_shared.so", "libc.so"],
        ]
        runner.answer = { arguments in
            let file = URL(fileURLWithPath: arguments.last!).lastPathComponent
            if arguments[0].hasSuffix("llvm-readelf") {
                return (needed[file] ?? []).map { " 0x0000000000000001 (NEEDED) Shared library: [\($0)]" }.joined(separator: "\n")
            }
            if arguments.contains("--undefined-only") {
                return file == "libswiftCore.so" ? "                 U _ZNSt6__ndk113__hash_memoryEPKvm\n                 U malloc" : ""
            }
            return missing ? "0000000000001000 T _ZNSt6__ndk14cout" : "0000000000001000 T _ZNSt6__ndk113__hash_memoryEPKvm"
        }
        return runner
    }

    @Test func stagesTheRuntimeTheLibraryNeeds() throws {
        let toolchain = toolchain()
        directory.write("app", to: "build/libapp.so")
        let staged = directory.url.appendingPathComponent("jniLibs/arm64-v8a")
        try toolchain.stage(directory.url.appendingPathComponent("build/libapp.so"), abi: .arm64, into: staged, runner: libraryTools())
        let names = try FileManager.default.contentsOfDirectory(atPath: staged.path).sorted()
        #expect(names == ["libFoundationEssentials.so", "libapp.so", "libc++_shared.so", "libswiftCore.so", "libswift_Concurrency.so"])
    }

    @Test func refusesAnNDKWhoseLibcxxIsTooOld() throws {
        let toolchain = toolchain()
        directory.write("app", to: "build/libapp.so")
        #expect(throws: PackagerError.self) {
            try toolchain.stage(directory.url.appendingPathComponent("build/libapp.so"), abi: .arm64,
                                into: directory.url.appendingPathComponent("jniLibs/arm64-v8a"), runner: libraryTools(missing: true))
        }
    }

    @Test func buildsEachABIWithItsSlice() throws {
        let host = Fixtures.hostPackage(in: directory)
        let url = Fixtures.bundle(in: directory, slices: [.arm64: 183])
        var options = Packager.Options(abis: [.arm64], hostPackage: host, androidSwiftUI: directory.url,
                                       workRoot: directory.url.appendingPathComponent("work"))
        options.output = .debugAPK
        let runner = libraryTools()
        let tools = runner.answer
        let bin = directory.url.appendingPathComponent("bin")
        directory.write("app", to: "bin/libapp.so")
        runner.answer = { (arguments: [String]) throws(PackagerError) -> String in
            if arguments.first == "swift" {
                return arguments.contains("--show-bin-path") ? "Planning…\n\(bin.path)\n" : ""
            }
            return try tools(arguments)
        }
        let packager = Packager(bundle: try UniversalBundle(url: url), options: options, toolchain: toolchain(), runner: runner)
        let (project, diagnostics) = try packager.prepare()
        #expect(diagnostics.allSatisfy { $0.severity == .warning })
        let build = try #require(runner.commands.first { $0.first == "swift" })
        #expect(build.contains("--triple") && build.contains("aarch64-unknown-linux-android28"))
        #expect(build.contains("app") && build.contains("debug"))
        #expect(runner.environments[runner.commands.firstIndex(of: build)!]["ANDROIDAPPRUNTIME_SLICE"]
                == url.appendingPathComponent("lib/android-arm64-v8a/libapp.a").path)
        #expect(FileManager.default.fileExists(atPath: project.jniLibs.appendingPathComponent("arm64-v8a/libswiftCore.so").path))
    }

    @Test func refusesToPackageWhatFailsValidation() throws {
        let host = Fixtures.hostPackage(in: directory)
        let url = Fixtures.bundle(in: directory, info: Fixtures.info(["CFBundleVersion": "beta"]))
        let options = Packager.Options(abis: [.arm64], hostPackage: host, androidSwiftUI: directory.url,
                                       workRoot: directory.url.appendingPathComponent("work"))
        let runner = FakeRunner()
        let packager = Packager(bundle: try UniversalBundle(url: url), options: options, toolchain: toolchain(), runner: runner)
        #expect(throws: PackagerError.self) {
            try packager.package()
        }
        #expect(runner.commands.isEmpty)
    }

    @Test func runsOnAnEmulatorUnlessToldOtherwise() throws {
        let runner = FakeRunner()
        runner.answer = { _ in "List of devices attached\nR58M123ABC\tdevice\nemulator-5556\toffline\nemulator-5554\tdevice\n" }
        let options = Packager.Options(abis: [.arm64], hostPackage: directory.url, androidSwiftUI: directory.url)
        let packager = Packager(bundle: try bundle(), options: options, toolchain: toolchain(), runner: runner)
        #expect(try packager.emulator() == "emulator-5554")
        runner.answer = { _ in "List of devices attached\nR58M123ABC\tdevice\n" }
        #expect(throws: PackagerError.self) {
            try packager.emulator()
        }
    }

    @Test func explainsAnInstallSignedWithAnotherKey() throws {
        let host = Fixtures.hostPackage(in: directory)
        let url = Fixtures.bundle(in: directory)
        let runner = libraryTools()
        let tools = runner.answer
        let bin = directory.url.appendingPathComponent("bin")
        directory.write("app", to: "bin/libapp.so")
        runner.answer = { (arguments: [String]) throws(PackagerError) -> String in
            switch arguments.first {
            case "swift": return arguments.contains("--show-bin-path") ? bin.path : ""
            case let tool? where tool.hasSuffix("gradlew"):
                self.directory.write("apk", to: "work/org.example.Weather/gradle/\(GradleProject.Output.debugAPK.path)")
                return ""
            case let tool? where tool.hasSuffix("adb") && arguments.contains("install"):
                throw PackagerError("Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: signatures do not match]")
            case let tool? where tool.hasSuffix("adb"):
                return ""
            default: return try tools(arguments)
            }
        }
        let options = Packager.Options(abis: [.arm64], hostPackage: host, androidSwiftUI: directory.url,
                                       workRoot: directory.url.appendingPathComponent("work"))
        let packager = Packager(bundle: try UniversalBundle(url: url), options: options, toolchain: toolchain(), runner: runner)
        #expect(throws: PackagerError.self) {
            try packager.run(serial: "emulator-5554")
        }
        #expect(!runner.commands.contains { $0.contains("uninstall") })
        #expect(throws: PackagerError.self) {
            try packager.run(serial: "emulator-5554", replace: true)
        }
        #expect(runner.commands.contains { $0.suffix(2) == ["uninstall", "org.example.Weather"] })
    }

    @Test func parsesTheNDKToolsOutput() {
        let dynamic = """
            Dynamic section at offset 0x1000 contains 3 entries:
              Tag                Type     Name/Value
              0x0000000000000001 (NEEDED) Shared library: [libswiftCore.so]
              0x000000000000000e (SONAME) Library soname: [libapp.so]
            """
        #expect(Toolchain.neededLibraries(dynamic) == ["libswiftCore.so"])
        #expect(Toolchain.symbols("                 U malloc\n0000000000001000 T main") == ["malloc", "main"])
    }
}
