import DynamicFiles
import RuntimeHost

/// The contract's operations, done synchronously: `HostFiles` for the
/// writable directories, run inline, and `BundleFiles` for `bundle`. Used
/// from one thread at a time.
struct FileEngine: @unchecked Sendable {

    /// An operation's answer.
    enum Outcome: Equatable {
        case complete
        case data([UInt8])
        case names([String])
        case attributes(FileAttributes)
        case failure(FileError)

        /// Calls the callback's method for this answer.
        func answer(_ callback: any FileCallback) {
            switch self {
            case .complete:
                callback.didComplete()
            case .data(let data):
                callback.didRead(data)
            case .names(let names):
                callback.didList(names)
            case .attributes(let attributes):
                callback.didGetAttributes(kind: attributes.kind.rawValue, size: attributes.size, modified: attributes.modified ?? 0)
            case .failure(let error):
                callback.didFail(error.rawValue)
            }
        }
    }

    /// The writable directories, answering before each call returns.
    let posix: HostFiles

    let bundle: BundleFiles

    /// Bytes a copy out of the bundle moves at a time.
    let copyChunk: Int

    /// Makes the writable directories and empties `temporary`; reads the
    /// bundle's index.
    init(_ configuration: AndroidFiles.Configuration) throws(FileError) {
        try HostFiles.configure(HostFiles.Configuration(
            directories: configuration.directories,
            maximumTransfer: configuration.maximumTransfer,
            work: { $0() },
            deliver: { $0() }
        ))
        self.posix = HostFiles.shared()
        self.bundle = BundleFiles(reader: configuration.assets ?? NoAssets(), maximumTransfer: configuration.maximumTransfer)
        self.copyChunk = min(1 << 20, configuration.maximumTransfer)
    }

    // MARK: Operations

    func read(_ directory: Int32, _ path: String, offset: Int64, length: Int64) -> Outcome {
        guard directory == FileDirectory.bundle.rawValue else {
            return posixCall { $0.read(directory, path: path, offset: offset, length: length, callback: $1) }
        }
        return attempt { () throws(FileError) in .data(try bundle.read(path, offset: offset, length: length)) }
    }

    func write(_ directory: Int32, _ path: String, data: [UInt8], mode: Int32) -> Outcome {
        // `HostFiles` answers `readOnly` for the bundle.
        posixCall { $0.write(directory, path: path, data: data, mode: mode, callback: $1) }
    }

    func list(_ directory: Int32, _ path: String) -> Outcome {
        guard directory == FileDirectory.bundle.rawValue else {
            return posixCall { $0.list(directory, path: path, callback: $1) }
        }
        return attempt { () throws(FileError) in .names(try bundle.list(path)) }
    }

    func attributes(_ directory: Int32, _ path: String) -> Outcome {
        guard directory == FileDirectory.bundle.rawValue else {
            return posixCall { $0.attributes(directory, path: path, callback: $1) }
        }
        return attempt { () throws(FileError) in .attributes(try bundle.attributes(path)) }
    }

    func makeDirectory(_ directory: Int32, _ path: String) -> Outcome {
        posixCall { $0.makeDirectory(directory, path: path, callback: $1) }
    }

    func remove(_ directory: Int32, _ path: String) -> Outcome {
        posixCall { $0.remove(directory, path: path, callback: $1) }
    }

    func move(_ directory: Int32, _ path: String, to toDirectory: Int32, _ toPath: String) -> Outcome {
        // Out of or into the bundle, `HostFiles` answers `readOnly`.
        posixCall { $0.move(directory, path: path, toDirectory: toDirectory, toPath: toPath, callback: $1) }
    }

    func copy(_ directory: Int32, _ path: String, to toDirectory: Int32, _ toPath: String) -> Outcome {
        guard directory == FileDirectory.bundle.rawValue else {
            // Into the bundle, `HostFiles` answers `readOnly`.
            return posixCall { $0.copy(directory, path: path, toDirectory: toDirectory, toPath: toPath, callback: $1) }
        }
        return attempt { () throws(FileError) in
            try copyOutOfBundle(path, to: toDirectory, toPath)
            return .complete
        }
    }

    // MARK: Copying out of the bundle

    /// Copies a file or a directory of the bundle to a writable directory,
    /// with the checks `HostFiles` makes for its own copies, in its order.
    private func copyOutOfBundle(_ path: String, to toDirectory: Int32, _ toPath: String) throws(FileError) {
        guard BundleIndex.isValid(path) else {
            throw .invalidPath
        }
        // Android has no document picker yet, so no directory but the app's
        // own is one a copy can go to.
        let destination = FileDirectory(rawValue: toDirectory)
        guard FileDirectory.allCases.contains(destination) else {
            throw .invalidPath
        }
        guard destination != .bundle else {
            throw .readOnly
        }
        guard BundleIndex.isValid(toPath), !path.isEmpty, !toPath.isEmpty else {
            // A directory itself can't be copied or replaced.
            throw .invalidPath
        }
        let kind = try bundle.kind(path)
        switch posixCall({ $0.attributes(toDirectory, path: toPath, callback: $1) }) {
        case .attributes:
            throw .alreadyExists
        case .failure(.notFound):
            break
        case .failure(let error):
            throw error
        default:
            throw .unknown
        }
        do throws(FileError) {
            switch kind {
            case .file(let size):
                try copyFile(path, size: size, to: toDirectory, toPath)
            case .directory:
                try complete(posixCall { $0.makeDirectory(toDirectory, path: toPath, callback: $1) })
                for entry in bundle.tree(path) {
                    let from = path + "/" + entry.path
                    let to = toPath + "/" + entry.path
                    if entry.isDirectory {
                        try complete(posixCall { $0.makeDirectory(toDirectory, path: to, callback: $1) })
                    } else {
                        guard case .file(let size) = try bundle.kind(from) else { throw .unknown }
                        try copyFile(from, size: size, to: toDirectory, to)
                    }
                }
            }
        } catch {
            // Leave nothing half-copied.
            _ = posixCall { $0.remove(toDirectory, path: toPath, callback: $1) }
            throw error
        }
    }

    /// A chunk at a time: the first replaces, which makes the directories
    /// above it, and the rest append.
    private func copyFile(_ path: String, size: Int64, to toDirectory: Int32, _ toPath: String) throws(FileError) {
        var offset: Int64 = 0
        repeat {
            let length = min(Int64(copyChunk), size - offset)
            let bytes = length > 0 ? try bundle.reader.read(BundleFiles.asset(path), offset: offset, length: length) : []
            guard let bytes else {
                throw .notFound
            }
            let mode = offset == 0 ? FileWriteMode.replace : FileWriteMode.append
            try complete(posixCall { $0.write(toDirectory, path: toPath, data: bytes, mode: mode.rawValue, callback: $1) })
            if bytes.isEmpty {
                // The asset is shorter than it said.
                break
            }
            offset += Int64(bytes.count)
        } while offset < size
    }

    private func complete(_ outcome: Outcome) throws(FileError) {
        switch outcome {
        case .complete:
            return
        case .failure(let error):
            throw error
        default:
            throw .unknown
        }
    }

    // MARK: Helpers

    /// Runs a `HostFiles` operation, which answers before it returns.
    private func posixCall(_ body: (HostFiles, Collector) -> Void) -> Outcome {
        let collector = Collector()
        body(posix, collector)
        return collector.outcome
    }

    private func attempt(_ operation: () throws(FileError) -> Outcome) -> Outcome {
        do throws(FileError) {
            return try operation()
        } catch {
            return .failure(error)
        }
    }
}

/// Keeps a `HostFiles` answer.
private final class Collector: FileCallback {

    var outcome: FileEngine.Outcome = .failure(.unknown)

    func didComplete() {
        outcome = .complete
    }

    func didRead(_ data: [UInt8]) {
        outcome = .data(data)
    }

    func didList(_ names: [String]) {
        outcome = .names(names)
    }

    func didGetAttributes(kind: Int32, size: Int64, modified: Int64) {
        outcome = .attributes(FileAttributes(kind: FileKind(rawValue: kind) ?? .file, size: size, modified: modified == 0 ? nil : modified))
    }

    func didFail(_ error: Int32) {
        outcome = .failure(FileError(rawValue: error) ?? .unknown)
    }
}

/// An APK without resources.
struct NoAssets: AssetReader {

    func length(_ path: String) -> Int64? {
        nil
    }

    func read(_ path: String, offset: Int64, length: Int64) throws(FileError) -> [UInt8]? {
        nil
    }
}
