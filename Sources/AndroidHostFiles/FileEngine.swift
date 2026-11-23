import DynamicFiles
import RuntimeHost

/// The contract's operations, done synchronously: `HostFiles` for the
/// writable directories and its own grants, run inline, `BundleFiles` for
/// `bundle`, and `DocumentFiles` for the documents the user gave
/// (`DocumentGrants.firstDirectory` and up). Used from one thread at a
/// time.
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

    let documents: DocumentFiles

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
        self.documents = DocumentFiles(store: configuration.content, maximumTransfer: configuration.maximumTransfer)
        self.copyChunk = min(1 << 20, configuration.maximumTransfer)
    }

    // MARK: Operations

    func read(_ directory: Int32, _ path: String, offset: Int64, length: Int64) -> Outcome {
        if Self.isDocument(directory) {
            return attempt { () throws(FileError) in .data(try documents.read(directory, path, offset: offset, length: length)) }
        }
        guard directory == FileDirectory.bundle.rawValue else {
            return posixCall { $0.read(directory, path: path, offset: offset, length: length, callback: $1) }
        }
        return attempt { () throws(FileError) in .data(try bundle.read(path, offset: offset, length: length)) }
    }

    func write(_ directory: Int32, _ path: String, data: [UInt8], mode: Int32) -> Outcome {
        if Self.isDocument(directory) {
            return attempt { () throws(FileError) in
                try documents.write(directory, path, data: data, mode: mode)
                return .complete
            }
        }
        // `HostFiles` answers `readOnly` for the bundle.
        return posixCall { $0.write(directory, path: path, data: data, mode: mode, callback: $1) }
    }

    func list(_ directory: Int32, _ path: String) -> Outcome {
        if Self.isDocument(directory) {
            return attempt { () throws(FileError) in .names(try documents.list(directory, path)) }
        }
        guard directory == FileDirectory.bundle.rawValue else {
            return posixCall { $0.list(directory, path: path, callback: $1) }
        }
        return attempt { () throws(FileError) in .names(try bundle.list(path)) }
    }

    func attributes(_ directory: Int32, _ path: String) -> Outcome {
        if Self.isDocument(directory) {
            return attempt { () throws(FileError) in .attributes(try documents.attributes(directory, path)) }
        }
        guard directory == FileDirectory.bundle.rawValue else {
            return posixCall { $0.attributes(directory, path: path, callback: $1) }
        }
        return attempt { () throws(FileError) in .attributes(try bundle.attributes(path)) }
    }

    func makeDirectory(_ directory: Int32, _ path: String) -> Outcome {
        if Self.isDocument(directory) {
            return attempt { () throws(FileError) in
                try documents.makeDirectory(directory, path)
                return .complete
            }
        }
        return posixCall { $0.makeDirectory(directory, path: path, callback: $1) }
    }

    func remove(_ directory: Int32, _ path: String) -> Outcome {
        if Self.isDocument(directory) {
            return attempt { () throws(FileError) in
                try documents.remove(directory, path)
                return .complete
            }
        }
        return posixCall { $0.remove(directory, path: path, callback: $1) }
    }

    func move(_ directory: Int32, _ path: String, to toDirectory: Int32, _ toPath: String) -> Outcome {
        if Self.isDocument(directory) || Self.isDocument(toDirectory) {
            return attempt { () throws(FileError) in
                try transfer(directory, path, to: toDirectory, toPath, removesSource: true)
                return .complete
            }
        }
        // Out of or into the bundle, `HostFiles` answers `readOnly`.
        return posixCall { $0.move(directory, path: path, toDirectory: toDirectory, toPath: toPath, callback: $1) }
    }

    func copy(_ directory: Int32, _ path: String, to toDirectory: Int32, _ toPath: String) -> Outcome {
        if Self.isDocument(directory) || Self.isDocument(toDirectory) {
            return attempt { () throws(FileError) in
                try transfer(directory, path, to: toDirectory, toPath, removesSource: false)
                return .complete
            }
        }
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
        // A copy into a document is `transfer`'s.
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

    // MARK: Moving and copying across documents

    /// A document the user gave. Grants below `DocumentGrants.firstDirectory`
    /// are `HostFiles`' own, and it answers for them.
    static func isDocument(_ directory: Int32) -> Bool {
        directory >= DocumentGrants.firstDirectory
    }

    /// A move or copy with a document on either side, made of reads, writes,
    /// listings and removes, with `HostFiles`' checks in its order. A move
    /// copies and then removes. What the user picked can be copied from,
    /// whole, but not moved.
    private func transfer(_ directory: Int32, _ path: String, to toDirectory: Int32, _ toPath: String, removesSource: Bool) throws(FileError) {
        try check(directory, path, writing: removesSource)
        try check(toDirectory, toPath, writing: true)
        let copiesDocument = path.isEmpty && !removesSource && Self.isDocument(directory)
        guard !path.isEmpty || copiesDocument, !toPath.isEmpty else {
            // A directory itself can't be moved, copied or replaced.
            throw .invalidPath
        }
        let kind = try attributesOf(directory, path).kind
        switch attributes(toDirectory, toPath) {
        case .attributes:
            throw .alreadyExists
        case .failure(.notFound):
            break
        case .failure(let error):
            throw error
        default:
            throw .unknown
        }
        if directory == toDirectory, toPath == path || toPath.hasPrefix(path + "/") {
            // Into itself.
            throw .invalidPath
        }
        do throws(FileError) {
            try copyTree(kind, directory, path, to: toDirectory, toPath)
        } catch {
            // Leave nothing half-copied.
            _ = remove(toDirectory, toPath)
            throw error
        }
        if removesSource {
            try complete(remove(directory, path))
        }
    }

    // MARK: For the documents' pickers

    /// What a provider says of each URI.
    func describe(_ uris: [String]) -> [Result<ContentInfo, FileError>] {
        uris.map { uri in
            guard let store = documents.store else {
                return .failure(.notPermitted)
            }
            do throws(FileError) {
                return .success(try store.info(uri))
            } catch {
                return .failure(error)
            }
        }
    }

    /// Whether `path` in `directory` is a file a save picker can copy.
    func checkExport(_ directory: Int32, _ path: String) throws(FileError) {
        guard try attributesOf(directory, path).kind == .file else {
            throw .isDirectory
        }
    }

    /// Copies the file at `path` in `directory` into the document at `uri`,
    /// which a save picker just made, a chunk at a time.
    func export(_ directory: Int32, _ path: String, to uri: String) throws(FileError) {
        guard let store = documents.store else {
            throw .notPermitted
        }
        var offset: Int64 = 0
        while true {
            let bytes = try data(read(directory, path, offset: offset, length: Int64(copyChunk)))
            try store.write(uri, data: bytes, append: offset > 0)
            offset += Int64(bytes.count)
            if bytes.count < copyChunk {
                break
            }
        }
    }

    /// What `transfer` checks of each side before it starts.
    private func check(_ directory: Int32, _ path: String, writing: Bool) throws(FileError) {
        if Self.isDocument(directory) {
            try documents.check(directory, path, writing: writing)
            return
        }
        let own = FileDirectory(rawValue: directory)
        guard FileDirectory.allCases.contains(own) else {
            throw .invalidPath
        }
        if writing, own == .bundle {
            throw .readOnly
        }
        guard BundleIndex.isValid(path) else {
            throw .invalidPath
        }
    }

    private func copyTree(_ kind: FileKind, _ directory: Int32, _ path: String, to toDirectory: Int32, _ toPath: String) throws(FileError) {
        switch kind {
        case .file:
            var offset: Int64 = 0
            var mode = FileWriteMode.replace
            while true {
                let bytes = try data(read(directory, path, offset: offset, length: Int64(copyChunk)))
                try complete(write(toDirectory, toPath, data: bytes, mode: mode.rawValue))
                mode = .append
                offset += Int64(bytes.count)
                if bytes.count < copyChunk {
                    break
                }
            }
        case .directory:
            try complete(makeDirectory(toDirectory, toPath))
            for name in try names(list(directory, path)) {
                let isDirectory = name.hasSuffix("/")
                let entry = isDirectory ? String(name.dropLast()) : name
                try copyTree(isDirectory ? .directory : .file,
                             directory, path.isEmpty ? entry : path + "/" + entry,
                             to: toDirectory, toPath + "/" + entry)
            }
        }
    }

    private func attributesOf(_ directory: Int32, _ path: String) throws(FileError) -> FileAttributes {
        switch attributes(directory, path) {
        case .attributes(let attributes):
            return attributes
        case .failure(let error):
            throw error
        default:
            throw .unknown
        }
    }

    private func data(_ outcome: Outcome) throws(FileError) -> [UInt8] {
        switch outcome {
        case .data(let bytes):
            return bytes
        case .failure(let error):
            throw error
        default:
            throw .unknown
        }
    }

    private func names(_ outcome: Outcome) throws(FileError) -> [String] {
        switch outcome {
        case .names(let names):
            return names
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
