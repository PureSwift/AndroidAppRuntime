import Foundation

/// The tools the packager runs (`Plan.md` §8): the Android SDK and NDK, the
/// Swift SDK for Android, a JDK for Gradle, and `adb`.
public struct Toolchain {

    /// `ANDROID_HOME`.
    public var androidHome: URL

    /// `ANDROID_NDK_HOME`, or the newest NDK in the SDK.
    public var ndk: URL

    /// The Swift SDK's ID, such as `swift-6.4.2-RELEASE_android`.
    public var swiftSDK: String

    /// The installed Swift SDKs: `~/Library/org.swift.swiftpm/swift-sdks`.
    public var swiftSDKs: URL

    /// A JDK Gradle 8.14 runs on (17 to 21), or `nil` for Gradle's own choice.
    public var javaHome: URL?

    public static let defaultSwiftSDK = "swift-6.4.2-RELEASE_android"

    public init(androidHome: URL, ndk: URL, swiftSDK: String = defaultSwiftSDK, swiftSDKs: URL, javaHome: URL? = nil) {
        self.androidHome = androidHome
        self.ndk = ndk
        self.swiftSDK = swiftSDK
        self.swiftSDKs = swiftSDKs
        self.javaHome = javaHome
    }

    /// Finds the tools from the environment and the usual places.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) throws(PackagerError) -> Toolchain {
        let files = FileManager.default
        let home = files.homeDirectoryForCurrentUser
        let androidHome = URL(fileURLWithPath: environment["ANDROID_HOME"] ?? environment["ANDROID_SDK_ROOT"]
            ?? home.appendingPathComponent("Library/Android/sdk").path)
        guard files.fileExists(atPath: androidHome.path) else {
            throw PackagerError("no Android SDK at \(androidHome.path); set ANDROID_HOME")
        }
        let ndk: URL
        if let path = environment["ANDROID_NDK_HOME"] {
            ndk = URL(fileURLWithPath: path)
        } else {
            let root = androidHome.appendingPathComponent("ndk")
            let versions = ((try? files.contentsOfDirectory(atPath: root.path)) ?? [])
                .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
            guard let newest = versions.last else {
                throw PackagerError("no NDK in \(root.path); install NDK r30, or set ANDROID_NDK_HOME")
            }
            ndk = root.appendingPathComponent(newest)
        }
        var swiftSDKs = home.appendingPathComponent("Library/org.swift.swiftpm/swift-sdks")
        if !files.fileExists(atPath: swiftSDKs.path) {
            swiftSDKs = home.appendingPathComponent(".swiftpm/swift-sdks")
        }
        let toolchain = Toolchain(
            androidHome: androidHome, ndk: ndk,
            swiftSDK: environment["SWIFT_ANDROID_SDK"] ?? defaultSwiftSDK,
            swiftSDKs: swiftSDKs,
            javaHome: javaHome(environment: environment)
        )
        guard files.fileExists(atPath: swiftSDKs.appendingPathComponent("\(toolchain.swiftSDK).artifactbundle").path) else {
            throw PackagerError("the Swift SDK \(toolchain.swiftSDK) isn't installed; see AndroidAppRuntime's README")
        }
        return toolchain
    }

    /// `JAVA_HOME`, else a JDK from 17 to 21 in the usual places.
    static func javaHome(environment: [String: String]) -> URL? {
        if let path = environment["JAVA_HOME"] {
            return URL(fileURLWithPath: path)
        }
        let candidates = [
            "/Applications/Android Studio.app/Contents/jbr/Contents/Home",
            "/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home",
            "/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home",
            "/usr/lib/jvm/java-21-openjdk-amd64",
            "/usr/lib/jvm/java-17-openjdk-amd64",
        ]
        return candidates.map(URL.init(fileURLWithPath:)).first { home in
            guard let release = try? String(contentsOf: home.appendingPathComponent("release"), encoding: .utf8),
                  let line = release.split(separator: "\n").first(where: { $0.hasPrefix("JAVA_VERSION=") }),
                  let major = Int(line.dropFirst("JAVA_VERSION=\"".count).prefix { $0.isNumber }) else {
                return false
            }
            return (17...21).contains(major)
        }
    }

    // MARK: Paths

    public var adb: URL {
        androidHome.appendingPathComponent("platform-tools/adb")
    }

    /// An LLVM tool of the NDK, such as `llvm-readelf`.
    public func llvmTool(_ name: String) -> URL {
        let prebuilt = ndk.appendingPathComponent("toolchains/llvm/prebuilt")
        let host = (try? FileManager.default.contentsOfDirectory(atPath: prebuilt.path))?.sorted().first ?? "darwin-x86_64"
        return prebuilt.appendingPathComponent("\(host)/bin/\(name)")
    }

    /// The Swift SDK's runtime libraries for `abi`.
    public func swiftRuntime(_ abi: AndroidABI) -> URL {
        swiftSDKs.appendingPathComponent("\(swiftSDK).artifactbundle/swift-android/swift-resources/usr/lib/swift-\(abi.arch)/android")
    }

    /// The NDK's `libc++_shared.so` for `abi`.
    public func libcxx(_ abi: AndroidABI) -> URL {
        llvmTool("x").deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("sysroot/usr/lib/\(abi.ndkTriple)/libc++_shared.so")
    }

    /// The environment for Gradle.
    public var gradleEnvironment: [String: String] {
        var environment = ["ANDROID_HOME": androidHome.path]
        if let javaHome {
            environment["JAVA_HOME"] = javaHome.path
        }
        return environment
    }

    // MARK: Staging

    /// Copies `library` into `directory` with the Swift runtime libraries it
    /// needs, from the Swift SDK, and the NDK's `libc++_shared.so`; the rest
    /// are the system's. Checks that this `libc++` has every symbol the
    /// runtime needs: the 6.4.2 SDK's needs NDK r30's.
    public func stage(_ library: URL, abi: AndroidABI, into directory: URL, runner: CommandRunning) throws(PackagerError) {
        let files = FileManager.default
        do {
            if files.fileExists(atPath: directory.path) {
                try files.removeItem(at: directory)
            }
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            try files.copyItem(at: library, to: directory.appendingPathComponent(library.lastPathComponent))
        } catch {
            throw PackagerError("can't stage the libraries into \(directory.path): \(error)")
        }
        let runtime = swiftRuntime(abi)
        var queue = [library]
        var staged: Set<String> = [library.lastPathComponent]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            let dynamic = try runner.run([llvmTool("llvm-readelf").path, "-d", current.path], directory: nil, environment: [:])
            for needed in Self.neededLibraries(dynamic) where !staged.contains(needed) {
                let source: URL
                if files.fileExists(atPath: runtime.appendingPathComponent(needed).path) {
                    source = runtime.appendingPathComponent(needed)
                    queue.append(source)
                } else if needed == "libc++_shared.so" {
                    source = libcxx(abi)
                } else {
                    continue
                }
                staged.insert(needed)
                do {
                    try files.copyItem(at: source, to: directory.appendingPathComponent(needed))
                } catch {
                    throw PackagerError("can't copy \(source.path): \(error)")
                }
            }
        }
        guard staged.contains("libc++_shared.so") else { return }
        var undefined = Set<String>()
        for name in staged {
            let symbols = try runner.run([llvmTool("llvm-nm").path, "-D", "--undefined-only", directory.appendingPathComponent(name).path],
                                         directory: nil, environment: [:])
            undefined.formUnion(Self.symbols(symbols).filter { $0.contains("__ndk1") })
        }
        let defined = Self.symbols(try runner.run([llvmTool("llvm-nm").path, "-D", "--defined-only",
                                                  directory.appendingPathComponent("libc++_shared.so").path],
                                                 directory: nil, environment: [:]))
        let missing = undefined.subtracting(defined).sorted()
        if !missing.isEmpty {
            throw PackagerError("""
                libc++_shared.so from \(ndk.path) lacks symbols the Swift runtime needs, such as \(missing.prefix(3).joined(separator: ", ")).
                Use a newer NDK (ANDROID_NDK_HOME); \(swiftSDK) needs NDK r30.
                """)
        }
    }

    /// The `NEEDED` libraries in `llvm-readelf -d`'s output.
    static func neededLibraries(_ output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            guard line.contains("(NEEDED)"), let open = line.firstIndex(of: "["), let close = line.lastIndex(of: "]") else {
                return nil
            }
            return String(line[line.index(after: open)..<close])
        }
    }

    /// The symbol names in `llvm-nm`'s output: each line's last field.
    static func symbols(_ output: String) -> Set<String> {
        Set(output.split(separator: "\n").compactMap { $0.split(separator: " ").last.map(String.init) })
    }
}
