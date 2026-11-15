import AndroidPackager
import ArgumentParser
import Foundation

/// `android-app`: turns a universal bundle into an Android app
/// (`Documentation/Plan.md` §8).
@main
struct AndroidApp: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "android-app",
        abstract: "Package AppRuntime apps for Android.",
        subcommands: [Validate.self, Package.self, Run.self, Gradle.self]
    )
}

/// What every command takes.
struct BundleOptions: ParsableArguments {

    @Argument(help: "The universal bundle, from guest.py bundle.")
    var bundle: String

    @Option(name: .customLong("abi"), help: "arm64-v8a, x86_64 or armeabi-v7a (repeatable); every ABI the bundle has by default.")
    var abis: [String] = []

    @Flag(help: "Warn about contracts this host lacks instead of failing; the app sees them as absent.")
    var allowMissingContracts = false

    @Option(help: "AndroidAppRuntime's source; ANDROIDAPPRUNTIME_PATH, or where android-app was built from.")
    var hostPackage: String?

    @Option(name: .customLong("androidswiftui"), help: "AndroidSwiftUI's checkout, for composeui; ANDROIDSWIFTUI_PATH, or one next to the host's.")
    var androidSwiftUI: String?

    @Option(help: "native (the bundle's slice) or wasm2c (App.wasm translated to C); the slice, else wasm2c, by default.")
    var engine: String?

    @Option(name: .customLong("appruntime"), help: "AppRuntime's checkout, for the wasm2c shim; APPRUNTIME_PATH, or one next to the host's.")
    var appRuntime: String?

    @Option(help: "The work directory for builds and Gradle projects.")
    var work = ".build/android-app"

    @Flag(name: .shortAndLong, help: "Show the commands the packager runs.")
    var verbose = false

    func preferredEngine() throws -> Engine? {
        guard let engine else { return nil }
        guard let value = Engine(rawValue: engine) else {
            throw ValidationError("unknown engine \(engine); native or wasm2c")
        }
        return value
    }

    func load() throws -> (UniversalBundle, [AndroidABI]) {
        let bundle = try UniversalBundle(url: URL(fileURLWithPath: self.bundle))
        var abis: [AndroidABI] = []
        for name in self.abis {
            guard let abi = AndroidABI(rawValue: name) else {
                throw ValidationError("unknown ABI \(name); one of \(AndroidABI.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            if !abis.contains(abi) {
                abis.append(abi)
            }
        }
        return (bundle, abis.isEmpty ? bundle.defaultABIs(engine: try preferredEngine()) : abis)
    }

    func packager() throws -> Packager {
        let (bundle, abis) = try load()
        let hostPackage = try Checkouts.hostPackage(self.hostPackage)
        var options = Packager.Options(
            abis: abis,
            hostPackage: hostPackage,
            androidSwiftUI: try Checkouts.androidSwiftUI(androidSwiftUI, hostPackage: hostPackage),
            workRoot: URL(fileURLWithPath: work)
        )
        options.allowMissingContracts = allowMissingContracts
        options.engine = try preferredEngine()
        options.appRuntime = Checkouts.appRuntime(appRuntime, hostPackage: hostPackage)
        return Packager(bundle: bundle, options: options, toolchain: try Toolchain.locate(), runner: CommandRunner(verbose: verbose))
    }
}

func report(_ diagnostics: [Diagnostic]) {
    for diagnostic in diagnostics {
        FileHandle.standardError.write(Data("\(diagnostic)\n".utf8))
    }
}

extension AndroidApp {

    struct Validate: ParsableCommand {

        static let configuration = CommandConfiguration(abstract: "Check that this host can run the app.")

        @OptionGroup var options: BundleOptions

        func run() throws {
            let (bundle, abis) = try options.load()
            var validator = Validator(bundle: bundle, abis: abis)
            validator.allowMissingContracts = options.allowMissingContracts
            validator.engine = try options.preferredEngine()
            let diagnostics = validator.validate()
            report(diagnostics)
            if diagnostics.contains(where: { $0.severity == .error }) {
                throw ExitCode.failure
            }
            print("ok: \(bundle.info.identifier) for \(abis.map(\.rawValue).joined(separator: ", "))")
        }
    }

    struct Package: ParsableCommand {

        static let configuration = CommandConfiguration(
            abstract: "Build a debug APK, or a signed release APK or App Bundle.",
            discussion: """
                A release needs --keystore and --alias. The passwords come from
                ANDROID_KEYSTORE_PASSWORD and ANDROID_KEY_PASSWORD (the keystore's by
                default), so they're never on the command line.
                """
        )

        @OptionGroup var options: BundleOptions

        @Flag(help: "A release build: optimized, minified and signed.")
        var release = false

        @Flag(help: "An App Bundle (.aab) for Play, instead of an APK. Implies --release.")
        var aab = false

        @Option(help: "The keystore that signs a release.")
        var keystore: String?

        @Option(help: "The key's alias in the keystore.")
        var alias: String?

        @Option(name: .shortAndLong, help: "Where to write the APK or AAB.")
        var output: String?

        func run() throws {
            var packager = try options.packager()
            packager.options.output = aab ? .bundle : release ? .releaseAPK : .debugAPK
            if let keystore {
                guard let alias else {
                    throw ValidationError("--keystore needs --alias")
                }
                packager.options.signing = .init(keystore: URL(fileURLWithPath: keystore).standardizedFileURL, alias: alias)
            }
            packager.options.destination = output.map { URL(fileURLWithPath: $0) }
            let result = try packager.package()
            report(result.diagnostics)
            print(result.artifact.path)
        }
    }

    struct Run: ParsableCommand {

        static let configuration = CommandConfiguration(abstract: "Install a debug build on a running emulator or a device, and start it.")

        @OptionGroup var options: BundleOptions

        @Option(help: "The device's serial (adb devices); ANDROID_SERIAL, or a running emulator.")
        var device: String?

        @Flag(help: "Uninstall a copy signed with another key, such as a release, and its data, first.")
        var replace = false

        func run() throws {
            let packager = try options.packager()
            let serial = device ?? ProcessInfo.processInfo.environment["ANDROID_SERIAL"]
            let (result, started) = try packager.run(serial: serial, replace: replace)
            report(result.diagnostics)
            print("started \(packager.bundle.info.identifier) on \(started)")
        }
    }

    struct Gradle: ParsableCommand {

        static let configuration = CommandConfiguration(abstract: "Write the app's Gradle project, with its libraries, for Android Studio.")

        @OptionGroup var options: BundleOptions

        func run() throws {
            let (project, diagnostics) = try options.packager().prepare()
            report(diagnostics)
            print(project.directory.path)
            FileHandle.standardError.write(Data("""
                Open it in Android Studio. Set ANDROIDSWIFTUI_PATH, or pass -PandroidSwiftUIPath to Gradle, for composeui.

                """.utf8))
        }
    }
}
