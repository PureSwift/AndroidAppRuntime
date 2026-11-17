import AndroidHost
import Dispatch
import DynamicFiles
import DynamicRuntime
import RuntimeHost

/// The `Files` contract on Android (`Plan.md` §6.5).
///
/// - `documents`, `data`, `caches` and `temporary` are directories under
///   the app's `filesDir` and `cacheDir`, which `HostFiles` handles as it
///   does on Linux and Darwin.
/// - `bundle` is the APK's assets under `rt/resources`, read through the
///   NDK's `AAssetManager`, and listed from the index the packager writes
///   beside them.
///
/// Every operation runs on one serial queue, so operations take effect in
/// the order they were issued, and answers on the main looper.
public final class AndroidFiles: Files {

    public struct Configuration {

        /// Where each writable directory is: an absolute path. `bundle` is
        /// left out; it's `assets`.
        public var directories: [FileDirectory: String]

        /// The APK's assets; `nil` for an empty bundle.
        public var assets: (any AssetReader)?

        /// The most bytes one read or write passes. More is `tooLarge`.
        public var maximumTransfer: Int

        /// Runs file work off the main thread, in order.
        public var work: @Sendable (@escaping @Sendable () -> Void) -> Void

        /// Runs an answer on the main thread.
        public var deliver: @Sendable (@escaping @Sendable () -> Void) -> Void

        public init(
            directories: [FileDirectory: String],
            assets: (any AssetReader)?,
            maximumTransfer: Int = 256 << 20,
            work: (@Sendable (@escaping @Sendable () -> Void) -> Void)? = nil,
            deliver: (@Sendable (@escaping @Sendable () -> Void) -> Void)? = nil
        ) {
            let queue = DispatchQueue(label: "org.pureswift.appruntime.files")
            self.directories = directories.filter { $0.key != .bundle }
            self.assets = assets
            self.maximumTransfer = maximumTransfer
            self.work = work ?? { queue.async(execute: $0) }
            self.deliver = deliver ?? { job in MainLooper.shared.post(job) }
        }

        /// The app's directories under `filesDir` and `cacheDir`.
        /// `caches` is a directory of its own, not `cacheDir` itself, so the
        /// app's caches aren't mixed with the WebView's and the system's.
        public static func directories(files: String, cache: String) -> [FileDirectory: String] {
            [
                .documents: files + "/Documents",
                .data: files + "/Data",
                .caches: cache + "/Caches",
                .temporary: cache + "/tmp",
            ]
        }
    }

    nonisolated(unsafe) private static var current: AndroidFiles?

    let engine: FileEngine

    let configuration: Configuration

    init(engine: FileEngine, configuration: Configuration) {
        self.engine = engine
        self.configuration = configuration
    }

    /// Sets where the app's files are, before the app starts. Makes the
    /// writable directories, empties `temporary`, and reads the bundle's
    /// index.
    public static func configure(_ configuration: Configuration) throws(FileError) {
        current = AndroidFiles(engine: try FileEngine(configuration), configuration: configuration)
    }

    /// The configured files. Before `configure`, every operation fails.
    public static func shared() -> AndroidFiles {
        if let current {
            return current
        }
        // With no directories there's nothing to make, so this can't fail.
        let configuration = Configuration(directories: [:], assets: nil)
        let files = AndroidFiles(engine: try! FileEngine(configuration), configuration: configuration)
        current = files
        return files
    }

    /// Runs `operation` off the main thread, and answers `callback` on it.
    private func run(_ callback: any FileCallback, _ operation: @escaping @Sendable (FileEngine) -> FileEngine.Outcome) {
        let engine = self.engine
        let deliver = configuration.deliver
        // The callback is the guest's, so only the main thread touches it,
        // releasing it included: `deliver` takes it out, and what the
        // worker's closures release is empty.
        let held = Held(callback)
        configuration.work {
            let outcome = Unchecked(operation(engine))
            deliver {
                guard let callback = held.take() else { return }
                outcome.value.answer(callback)
            }
        }
    }

    public func read(_ directory: Int32, path: String, offset: Int64, length: Int64, callback: any FileCallback) {
        run(callback) { $0.read(directory, path, offset: offset, length: length) }
    }

    public func write(_ directory: Int32, path: String, data: [UInt8], mode: Int32, callback: any FileCallback) {
        let data = Unchecked(data)
        run(callback) { $0.write(directory, path, data: data.value, mode: mode) }
    }

    public func list(_ directory: Int32, path: String, callback: any FileCallback) {
        run(callback) { $0.list(directory, path) }
    }

    public func attributes(_ directory: Int32, path: String, callback: any FileCallback) {
        run(callback) { $0.attributes(directory, path) }
    }

    public func makeDirectory(_ directory: Int32, path: String, callback: any FileCallback) {
        run(callback) { $0.makeDirectory(directory, path) }
    }

    public func remove(_ directory: Int32, path: String, callback: any FileCallback) {
        run(callback) { $0.remove(directory, path) }
    }

    public func move(_ directory: Int32, path: String, toDirectory: Int32, toPath: String, callback: any FileCallback) {
        run(callback) { $0.move(directory, path, to: toDirectory, toPath) }
    }

    public func copy(_ directory: Int32, path: String, toDirectory: Int32, toPath: String, callback: any FileCallback) {
        run(callback) { $0.copy(directory, path, to: toDirectory, toPath) }
    }
}

/// The files module: `Files` and its callback.
public enum AndroidHostFiles: HostModule {

    public static var contracts: [ContractDescriptor] {
        [FilesProxy.descriptor, FileCallbackProxy.descriptor]
    }

    public static func register(in registrar: some ContractRegistrar) {
        FilesProxy.register(AndroidFiles.self, in: registrar)
        FileCallbackProxy.registerInterface(in: registrar)
    }
}

/// One of the runtime's objects, carried through work on another thread
/// for the main thread to take out, so it's released there: a proxy's last
/// release tells the runtime, which belongs to the main thread.
final class Held<Value>: @unchecked Sendable {

    private var value: Value?

    /// Call on the main thread.
    init(_ value: Value) {
        self.value = value
    }

    /// The object, the caller's from here on; `nil` the second time. Call
    /// on the main thread.
    func take() -> Value? {
        defer { value = nil }
        return value
    }
}

/// Carries a value the compiler can't see is used on one thread at a time.
struct Unchecked<Value>: @unchecked Sendable {

    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
