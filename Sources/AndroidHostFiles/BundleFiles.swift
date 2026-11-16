import DynamicFiles

/// The `bundle` directory: the APK's assets under `rt/resources`, read
/// synchronously. What's in it comes from the packager's index; the bytes
/// and sizes from the assets themselves. An asset has no modification
/// date.
struct BundleFiles: Sendable {

    /// Where the packager puts the resources in the APK's assets.
    static let root = "rt/resources"

    /// The packager's list of the resources' files.
    static let indexPath = "rt/resources.index"

    let reader: any AssetReader

    let index: BundleIndex

    let maximumTransfer: Int

    /// Reads the index once. An APK without one has an empty bundle.
    init(reader: any AssetReader, maximumTransfer: Int) {
        self.reader = reader
        self.maximumTransfer = maximumTransfer
        let length = reader.length(Self.indexPath) ?? 0
        let text = (try? reader.read(Self.indexPath, offset: 0, length: length)) ?? nil
        self.index = BundleIndex(text: text ?? [])
    }

    enum Kind {
        case file(size: Int64)
        case directory
    }

    static func asset(_ path: String) -> String {
        path.isEmpty ? root : root + "/" + path
    }

    /// What's at `path`: `invalidPath`, or `notDirectory` when a file is on
    /// the way, or `notFound`.
    func kind(_ path: String) throws(FileError) -> Kind {
        guard BundleIndex.isValid(path) else {
            throw .invalidPath
        }
        if index.directories[path] != nil {
            return .directory
        }
        if index.passesThroughFile(path) {
            throw .notDirectory
        }
        guard index.files.contains(path), let size = reader.length(Self.asset(path)) else {
            throw .notFound
        }
        return .file(size: size)
    }

    func read(_ path: String, offset: Int64, length: Int64) throws(FileError) -> [UInt8] {
        guard case .file(let size) = try kind(path) else {
            throw .isDirectory
        }
        guard offset >= 0, length >= -1 else {
            throw .unknown
        }
        let available = max(size - offset, 0)
        let wanted = length < 0 ? available : min(length, available)
        guard wanted <= Int64(maximumTransfer) else {
            throw .tooLarge
        }
        guard wanted > 0 else {
            return []
        }
        guard let bytes = try reader.read(Self.asset(path), offset: offset, length: wanted) else {
            throw .notFound
        }
        return bytes
    }

    /// Names sorted by their bytes; a directory's ends in `/`.
    func list(_ path: String) throws(FileError) -> [String] {
        guard case .directory = try kind(path) else {
            throw .notDirectory
        }
        return (index.directories[path] ?? []).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    func attributes(_ path: String) throws(FileError) -> FileAttributes {
        switch try kind(path) {
        case .directory:
            return FileAttributes(kind: .directory, size: 0, modified: nil)
        case .file(let size):
            return FileAttributes(kind: .file, size: size, modified: nil)
        }
    }

    /// The files under the directory at `path`, and the directories, each
    /// listed before what's in it; paths relative to `path`.
    func tree(_ path: String) -> [(path: String, isDirectory: Bool)] {
        var entries: [(path: String, isDirectory: Bool)] = []
        for name in (index.directories[path] ?? []).sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
            if name.hasSuffix("/") {
                let child = String(name.dropLast())
                entries.append((child, true))
                let full = path.isEmpty ? child : path + "/" + child
                entries += tree(full).map { (child + "/" + $0.path, $0.isDirectory) }
            } else {
                entries.append((name, false))
            }
        }
        return entries
    }
}
