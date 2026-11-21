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
/// - A document the user gave (`DocumentGrants`) is a content URI, read
///   and written through the Storage Access Framework (§6.8).
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

        /// Where the documents the user gives are read and written; `nil`
        /// for a host with no pickers.
        public var content: (any ContentStore)?

        /// The most bytes one read or write passes. More is `tooLarge`.
        public var maximumTransfer: Int

        /// Runs file work off the main thread, in order.
        public var work: @Sendable (@escaping @Sendable () -> Void) -> Void

        /// Runs an answer on the main thread.
        public var deliver: @Sendable (@escaping @Sendable () -> Void) -> Void

        public init(
            directories: [FileDirectory: String],
            assets: (any AssetReader)?,
            content: (any ContentStore)? = nil,
            maximumTransfer: Int = 256 << 20,
            work: (@Sendable (@escaping @Sendable () -> Void) -> Void)? = nil,
            deliver: (@Sendable (@escaping @Sendable () -> Void) -> Void)? = nil
        ) {
            let queue = DispatchQueue(label: "org.pureswift.appruntime.files")
            self.directories = directories.filter { $0.key != .bundle }
            self.assets = assets
            self.content = content
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

    /// The URI of `path` in a document the user gave, for another contract
    /// that's handed a directory and a path. Off the main thread: it may
    /// ask the provider.
    public func contentURI(of directory: Int32, path: String) throws(FileError) -> String {
        try engine.documents.uri(of: directory, path: path)
    }

    // MARK: For the documents' pickers

    /// Runs `operation` on the files queue, in order with every other file
    /// operation, and `completion` with its result on the main thread.
    private func perform<Value>(_ operation: @escaping @Sendable (FileEngine) -> Value, completion: @escaping (Value) -> Void) {
        let engine = self.engine
        let deliver = configuration.deliver
        let held = Held(completion)
        configuration.work {
            let value = Unchecked(operation(engine))
            deliver {
                held.take()?(value.value)
            }
        }
    }

    /// What the provider says of each URI a picker gave.
    public func describe(_ uris: [String], completion: @escaping ([Result<ContentInfo, FileError>]) -> Void) {
        perform({ $0.describe(uris) }, completion: completion)
    }

    /// Whether `path` in `directory` is a file a save picker can copy:
    /// `nil` when it is.
    public func checkExport(_ directory: Int32, path: String, completion: @escaping (FileError?) -> Void) {
        perform({ engine in
            do throws(FileError) {
                try engine.checkExport(directory, path)
                return nil
            } catch {
                return error
            }
        }, completion: completion)
    }

    /// Copies the file at `path` in `directory` into the document at `uri`,
    /// which a save picker made: `nil` when it's copied.
    public func export(_ directory: Int32, path: String, to uri: String, completion: @escaping (FileError?) -> Void) {
        perform({ engine in
            do throws(FileError) {
                try engine.export(directory, path, to: uri)
                return nil
            } catch {
                return error
            }
        }, completion: completion)
    }

    /// The APK asset a file of the bundle is, for another contract that's
    /// handed one: a media player. A directory, or nothing, is `notFound`.
    public func bundleAsset(_ path: String) throws(FileError) -> String {
        guard BundleIndex.isValid(path), !path.isEmpty, case .file = try engine.bundle.kind(path) else {
            throw .notFound
        }
        return BundleFiles.asset(path)
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
