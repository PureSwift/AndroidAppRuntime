import Foundation

/// `android-app package`, `run` and `gradle` (`Plan.md` §8): validates the
/// bundle, builds `libapp.so` for each ABI with the bundle's slice linked
/// in, writes the Gradle project, and has Gradle make the APK or App Bundle.
public struct Packager {

    public struct Options {
        public var abis: [AndroidABI]
        public var output: GradleProject.Output = .debugAPK
        public var signing: GradleProject.Signing?
        public var allowMissingContracts = false
        /// Where the APK or AAB goes; `<work>/out` if `nil`.
        public var destination: URL?
        /// AndroidAppRuntime's checkout.
        public var hostPackage: URL
        /// AndroidSwiftUI's checkout, for composeui.
        public var androidSwiftUI: URL
        /// `.build/android-app` in the current directory by default.
        public var workRoot: URL

        public init(abis: [AndroidABI], hostPackage: URL, androidSwiftUI: URL,
                    workRoot: URL = URL(fileURLWithPath: ".build/android-app")) {
            self.abis = abis
            self.hostPackage = hostPackage
            self.androidSwiftUI = androidSwiftUI
            self.workRoot = workRoot
        }
    }

    /// What `package` made.
    public struct Result {
        /// The APK or AAB.
        public var artifact: URL
        public var project: URL
        public var diagnostics: [Diagnostic]
    }

    public var bundle: UniversalBundle

    public var options: Options

    public var toolchain: Toolchain

    public var runner: CommandRunning

    public init(bundle: UniversalBundle, options: Options, toolchain: Toolchain, runner: CommandRunning = CommandRunner()) {
        self.bundle = bundle
        self.options = options
        self.toolchain = toolchain
        self.runner = runner
    }

    /// The app's work directory: its Swift builds and its Gradle project.
    public var work: URL {
        options.workRoot.appendingPathComponent(bundle.info.identifier)
    }

    public var project: GradleProject {
        GradleProject(directory: work.appendingPathComponent("gradle"), hostPackage: options.hostPackage,
                      bundle: bundle, abis: options.abis, signing: options.signing)
    }

    public func validate() -> [Diagnostic] {
        var validator = Validator(bundle: bundle, abis: options.abis)
        validator.allowMissingContracts = options.allowMissingContracts
        return validator.validate()
    }

    /// Validates, builds the libraries and writes the Gradle project, ready
    /// for Gradle or Android Studio.
    public func prepare() throws(PackagerError) -> (GradleProject, [Diagnostic]) {
        let diagnostics = validate()
        let errors = diagnostics.filter { $0.severity == .error }
        guard errors.isEmpty else {
            throw PackagerError(errors.map(\.description).joined(separator: "\n"))
        }
        let project = self.project
        try project.write()
        for abi in options.abis {
            let library = try buildLibrary(abi)
            try toolchain.stage(library, abi: abi, into: project.jniLibs.appendingPathComponent(abi.rawValue), runner: runner)
        }
        try removeOtherABIs(from: project)
        return (project, diagnostics)
    }

    /// Prepares the project and has Gradle build the APK or AAB, copied to
    /// `<work>/out/<identifier>-<version>.<apk|aab>` or the destination.
    public func package() throws(PackagerError) -> Result {
        let (project, diagnostics) = try prepare()
        let built = try project.build(options.output, androidSwiftUI: options.androidSwiftUI, toolchain: toolchain, runner: runner)
        let version = bundle.info.version.isEmpty ? bundle.info.build : bundle.info.version
        let suffix = options.output == .debugAPK ? "-debug" : ""
        let destination = options.destination
            ?? work.appendingPathComponent("out/\(bundle.info.identifier)-\(version)\(suffix).\(options.output.fileExtension)")
        do {
            let files = FileManager.default
            try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if files.fileExists(atPath: destination.path) {
                try files.removeItem(at: destination)
            }
            try files.copyItem(at: built, to: destination)
        } catch {
            throw PackagerError("can't copy \(built.path) to \(destination.path): \(error)")
        }
        return Result(artifact: destination, project: project.directory, diagnostics: diagnostics)
    }

    /// Builds the host's `libapp.so` for `abi` with the bundle's slice; its
    /// path. Each ABI has its own scratch directory in the work directory.
    func buildLibrary(_ abi: AndroidABI) throws(PackagerError) -> URL {
        guard let slice = bundle.slice(abi) else {
            throw PackagerError("the bundle has no \(abi.target) slice")
        }
        let configuration = options.output == .debugAPK ? "debug" : "release"
        let arguments = ["swift", "build", "--package-path", options.hostPackage.path,
                         "--scratch-path", work.appendingPathComponent("swift/\(abi.rawValue)").path,
                         "--swift-sdk", toolchain.swiftSDK, "--triple", abi.triple,
                         "-c", configuration, "--product", "app"]
        // The host package links the slice when this is set.
        let environment = ["ANDROIDAPPRUNTIME_SLICE": slice.path]
        try runner.run(arguments, directory: nil, environment: environment)
        let bin = try runner.run(arguments + ["--show-bin-path"], directory: nil, environment: environment)
            .split(separator: "\n").last.map(String.init) ?? ""
        let library = URL(fileURLWithPath: bin.trimmingCharacters(in: .whitespaces)).appendingPathComponent("libapp.so")
        guard FileManager.default.fileExists(atPath: library.path) else {
            throw PackagerError("swift build didn't make \(library.path)")
        }
        return library
    }

    /// Drops the libraries of ABIs an earlier build had and this one doesn't.
    private func removeOtherABIs(from project: GradleProject) throws(PackagerError) {
        let wanted = Set(options.abis.map(\.rawValue))
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: project.jniLibs.path)) ?? []
        for name in existing where !wanted.contains(name) {
            do {
                try FileManager.default.removeItem(at: project.jniLibs.appendingPathComponent(name))
            } catch {
                throw PackagerError("can't remove \(name)'s libraries: \(error)")
            }
        }
    }

    // MARK: Running

    /// Packages a debug APK, installs it on `serial` (or a running emulator),
    /// and starts it. With `replace`, an installed copy signed with another
    /// key, such as a release, is uninstalled first, with its data.
    public func run(serial: String?, replace: Bool = false) throws(PackagerError) -> (Result, String) {
        var debug = self
        debug.options.output = .debugAPK
        let result = try debug.package()
        var device = serial ?? ""
        if device.isEmpty {
            device = try emulator()
        }
        let adb = toolchain.adb.path
        if replace {
            _ = try? runner.run([adb, "-s", device, "uninstall", bundle.info.identifier], directory: nil, environment: [:])
        }
        do {
            try runner.run([adb, "-s", device, "install", "-r", result.artifact.path], directory: nil, environment: [:])
        } catch where error.message.contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE") {
            throw PackagerError("""
                \(device) has \(bundle.info.identifier) signed with another key, such as a release build.
                Pass --replace to uninstall it, and its data, first.
                """)
        }
        try runner.run([adb, "-s", device, "shell", "am", "start", "-n",
                        "\(bundle.info.identifier)/org.pureswift.appruntime.AppRuntimeActivity"], directory: nil, environment: [:])
        return (result, device)
    }

    /// A running emulator: a phone that's plugged in isn't used unasked.
    func emulator() throws(PackagerError) -> String {
        let devices = try runner.run([toolchain.adb.path, "devices"], directory: nil, environment: [:])
        for line in devices.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.count == 2, fields[0].hasPrefix("emulator-"), fields[1] == "device" {
                return String(fields[0])
            }
        }
        throw PackagerError("no emulator is running; start one, or pass --device")
    }
}

/// Where the packager's inputs are.
public enum Checkouts {

    /// AndroidAppRuntime's source: `--host-package`, then
    /// `ANDROIDAPPRUNTIME_PATH`, then the tree `android-app` was built from.
    public static func hostPackage(_ explicit: String? = nil) throws(PackagerError) -> URL {
        let candidates = [explicit, ProcessInfo.processInfo.environment["ANDROIDAPPRUNTIME_PATH"]].compactMap { $0 }
            .map { URL(fileURLWithPath: $0) }
            + [URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()]
        for candidate in candidates {
            let manifest = candidate.appendingPathComponent("Package.swift")
            if let text = try? String(contentsOf: manifest, encoding: .utf8), text.contains("name: \"AndroidAppRuntime\"") {
                return candidate.standardizedFileURL
            }
        }
        throw PackagerError("can't find AndroidAppRuntime's source; pass --host-package or set ANDROIDAPPRUNTIME_PATH")
    }

    /// AndroidSwiftUI's checkout, for composeui: `--androidswiftui`, then
    /// `ANDROIDSWIFTUI_PATH`, then one next to the host's.
    public static func androidSwiftUI(_ explicit: String? = nil, hostPackage: URL) throws(PackagerError) -> URL {
        let candidates = [explicit, ProcessInfo.processInfo.environment["ANDROIDSWIFTUI_PATH"]].compactMap { $0 }
            .map { URL(fileURLWithPath: $0) }
            + [hostPackage.deletingLastPathComponent().appendingPathComponent("AndroidSwiftUI")]
        for candidate in candidates
        where FileManager.default.fileExists(atPath: candidate.appendingPathComponent("composeui/src/commonMain").path) {
            return candidate.standardizedFileURL
        }
        throw PackagerError("can't find AndroidSwiftUI's composeui; pass --androidswiftui or set ANDROIDSWIFTUI_PATH")
    }
}
