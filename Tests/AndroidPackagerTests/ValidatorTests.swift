@testable import AndroidPackager
import Foundation
import RuntimeABI
import Testing

/// Reading bundles and the packager's checks.
@Suite struct ValidatorTests {

    let directory = TemporaryDirectory()

    func validate(_ info: [String: Any] = Fixtures.info(), slices: [AndroidABI: UInt16] = [.arm64: 183],
                  abis: [AndroidABI] = [.arm64], allowMissing: Bool = false) throws -> [Diagnostic] {
        let bundle = try UniversalBundle(url: Fixtures.bundle(in: directory, info: info, slices: slices))
        var validator = Validator(bundle: bundle, abis: abis)
        validator.allowMissingContracts = allowMissing
        return validator.validate()
    }

    @Test func readsTheBundlesAndroidSettings() throws {
        let info = Fixtures.info([
            "RTPlatformExtras": ["android": ["extraManifest": "<queries />"]],
            "RTCapabilityOptions": ["bluetooth": ["required": "true"]],
        ])
        let bundle = try UniversalBundle(url: Fixtures.bundle(in: directory, info: info, slices: [.arm64: 183, .x86_64: 62]))
        #expect(bundle.info.identifier == "org.example.Weather")
        #expect(bundle.displayName == "Weather")
        #expect(bundle.platforms == ["android", "ios"])
        #expect(bundle.minSDK == 26)
        #expect(bundle.targetSDK == 35)
        #expect(bundle.extraManifest == "<queries />")
        #expect(bundle.capabilityOptions == ["bluetooth": ["required": "true"]])
        #expect(bundle.abis == [.arm64, .x86_64])
        #expect(bundle.icon == nil)
    }

    @Test func readsLocalizedNames() throws {
        let bundle = try UniversalBundle(url: Fixtures.bundle(in: directory, names: ["en": "Weather", "es": "Tiempo"]))
        #expect(bundle.localizedDisplayNames == ["en": "Weather", "es": "Tiempo"])
    }

    @Test func refusesWhatIsntABundle() {
        #expect(throws: PackagerError.self) {
            try UniversalBundle(url: directory.url)
        }
    }

    @Test func passesAnAppThatFits() throws {
        let diagnostics = try validate()
        #expect(diagnostics == [.warning("minSDK 26 is raised to 28, the Swift SDK for Android's")])
    }

    @Test func checksTheIdentifierAndBuild() throws {
        let diagnostics = try validate(Fixtures.info(["CFBundleIdentifier": "org.example.my-app", "CFBundleVersion": "1.2"]))
        #expect(diagnostics.filter { $0.severity == .error }.count == 2)
        #expect(Validator.isApplicationID("org.example.Weather_2"))
        #expect(!Validator.isApplicationID("Weather"))
        #expect(!Validator.isApplicationID("org.2example.App"))
        #expect(Validator.versionCode("42") == 42)
        #expect(Validator.versionCode("0") == nil)
    }

    @Test func needsTheAndroidPlatform() throws {
        let diagnostics = try validate(Fixtures.info(["RTPlatforms": ["ios": ["Minimum": "15.0"]]]))
        #expect(diagnostics.contains(.error("the app's manifest doesn't list the android platform")))
        // Without a manifest there's nothing to check against.
        var info = Fixtures.info()
        info["RTPlatforms"] = nil
        #expect(try validate(info).allSatisfy { $0.severity == .warning })
    }

    @Test func checksContracts() throws {
        let missing: [String: Any] = ["Name": "org.pureswift.camera.Session", "Version": 1, "Kind": "contract"]
        let newer: [String: Any] = ["Name": "org.pureswift.ui.Renderer", "Version": 9, "Kind": "contract"]
        let info = Fixtures.info(["RTContracts": [missing, newer]])
        let errors = try validate(info).filter { $0.severity == .error }
        #expect(errors == [.error("org.pureswift.camera.Session isn't implemented on Android")])
        let relaxed = try validate(info, allowMissing: true)
        #expect(relaxed.allSatisfy { $0.severity == .warning })
        #expect(relaxed.contains(.warning("org.pureswift.ui.Renderer is version 1 on Android; the app was built against 9")))
    }

    @Test func servesSurfacesForTheGraphicsCapability() throws {
        let surface: [String: Any] = ["Name": "org.pureswift.graphics.Surface", "Version": 1, "Kind": "contract"]
        let delegate: [String: Any] = ["Name": "org.pureswift.graphics.SurfaceDelegate", "Version": 1, "Kind": "callback"]
        let info = Fixtures.info(["RTCapabilities": ["graphics"], "RTContracts": [Fixtures.renderer, surface, delegate]])
        let diagnostics = try validate(info)
        #expect(!diagnostics.contains { $0.severity == .error })
        #expect(!diagnostics.contains { $0.message.contains("graphics") })
    }

    @Test func runsBackgroundTasks() throws {
        let tasks: [String: Any] = ["Name": "org.pureswift.background.Tasks", "Version": 1, "Kind": "contract"]
        let delegate: [String: Any] = ["Name": "org.pureswift.background.TasksDelegate", "Version": 1, "Kind": "callback"]
        let callback: [String: Any] = ["Name": "org.pureswift.background.Callback", "Version": 1, "Kind": "callback"]
        let info = Fixtures.info(["RTCapabilities": ["backgroundTasks"], "RTContracts": [Fixtures.renderer, tasks, delegate, callback],
                                  "RTBackgroundTasks": [["Identifier": "org.example.sync", "Kind": "refresh"]]])
        let diagnostics = try validate(info)
        #expect(!diagnostics.contains { $0.severity == .error })
        #expect(!diagnostics.contains { $0.message.contains("backgroundTasks") })
    }

    @Test func checksSlices() throws {
        let wrong = try validate(slices: [.arm64: 62])
        #expect(wrong.contains(.error("android-arm64-v8a slice: objects are for ELF machine [62], not 183 (aarch64)")))
        let missing = try validate(abis: [.arm64, .x86_64])
        #expect(missing.contains(.error("the bundle has no android-x86_64 slice, and no App.wasm for wasm2c")))
        let none = try validate(slices: [:], abis: [])
        #expect(none.contains { $0.message.hasPrefix("the bundle has no Android slices") })
        let untested = try validate(slices: [.armv7: 40], abis: [.armv7])
        #expect(untested.contains(.warning("armeabi-v7a isn't tested on hardware yet")))
    }

    @Test func choosesAnEngine() throws {
        let url = Fixtures.bundle(in: directory, wasm: true)
        let bundle = try UniversalBundle(url: url)
        #expect(bundle.engine(for: .arm64) == .native)
        #expect(bundle.engine(for: .x86_64) == .wasm2c)
        #expect(bundle.engine(for: .arm64, preferred: .wasm2c) == .wasm2c)
        #expect(bundle.defaultABIs() == [.arm64])
        #expect(bundle.defaultABIs(engine: .wasm2c) == [.arm64, .x86_64])
        var validator = Validator(bundle: bundle, abis: [.arm64, .x86_64])
        let automatic = validator.validate()
        #expect(automatic.contains(.warning("the bundle has no android-x86_64 slice; App.wasm is translated with wasm2c")))
        #expect(automatic.allSatisfy { $0.severity == .warning })
        validator.engine = .native
        #expect(validator.validate().contains(.error("the bundle has no android-x86_64 slice; App.wasm can stand in with --engine wasm2c")))
        validator.engine = .wasm2c
        #expect(validator.validate().allSatisfy { $0.severity == .warning && !$0.message.contains("wasm2c") })
    }

    @Test func readsWasmSections() {
        let sections = WasmModule.customSections(Fixtures.wasm(sections: ["rt.abi": [1, 0, 0, 0], "name": [9]]))
        #expect(sections == ["rt.abi": Data([1, 0, 0, 0]), "name": Data([9])])
        #expect(WasmModule.customSections(Data("not wasm".utf8)).isEmpty)
        #expect(WasmModule.customSections(Data([0, 0x61, 0x73, 0x6D, 1, 0, 0, 0, 0, 0x7F])).isEmpty, "a truncated section")
    }

    @Test func checksIntegrity() throws {
        let url = Fixtures.bundle(in: directory, sign: true)
        #expect(try UniversalBundle(url: url).codeResourceProblems().isEmpty)
        directory.write(Fixtures.archive(machine: 62), to: "Weather.app/lib/android-arm64-v8a/libapp.a")
        directory.write("extra", to: "Weather.app/resources/extra.txt")
        let problems = try UniversalBundle(url: url).codeResourceProblems()
        #expect(problems == ["lib/android-arm64-v8a/libapp.a was modified", "resources/extra.txt was added"])
    }

    @Test func warnsAboutCapabilitiesItDoesntServe() throws {
        // A capability from a newer AppRuntime.
        let diagnostics = try validate(Fixtures.info(["RTCapabilities": ["healthData", "camera", "microphone", "location", "network"]]))
        #expect(diagnostics.contains(.warning("the app declares healthData, which the Android host doesn't serve yet; it gets the permissions only")))
        #expect(!diagnostics.contains { $0.message.contains("declares network") || $0.message.contains("declares location") })
        #expect(!diagnostics.contains { $0.message.contains("declares camera") || $0.message.contains("declares microphone") })
    }
}
