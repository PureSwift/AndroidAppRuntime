import AndroidHost
import DynamicFiles

/// What a provider says of a document.
public struct ContentInfo: Equatable, Sendable {

    /// What the provider calls it, with its extension.
    public var name: String

    /// A MIME type, where the provider gives one; `nil` for a folder.
    public var contentType: String?

    public var kind: FileKind

    /// Bytes; 0 for a folder.
    public var size: Int64

    /// Milliseconds since 1970 UTC, where the provider knows.
    public var modified: Int64?

    /// Whether the provider takes writes: to a file's contents, or new
    /// children of a folder.
    public var isWritable: Bool

    public init(name: String, contentType: String? = nil, kind: FileKind = .file, size: Int64 = 0, modified: Int64? = nil, isWritable: Bool = true) {
        self.name = name
        self.contentType = contentType
        self.kind = kind
        self.size = size
        self.modified = modified
        self.isWritable = isWritable
    }
}

/// One entry of a folder.
public struct ContentChild: Equatable, Sendable {

    public var uri: String

    public var name: String

    public var kind: FileKind

    public init(uri: String, name: String, kind: FileKind) {
        self.uri = uri
        self.name = name
        self.kind = kind
    }
}

/// The Storage Access Framework's documents, by content URI: the Kotlin
/// `DocumentSystem` on a device. Called on the files queue; each call
/// blocks until the provider answers.
public protocol ContentStore: AnyObject {

    func info(_ uri: String) throws(FileError) -> ContentInfo

    /// A folder's entries, in the provider's order.
    func children(_ uri: String) throws(FileError) -> [ContentChild]

    /// Up to `length` bytes from `offset`; to the end when `length` is −1.
    func read(_ uri: String, offset: Int64, length: Int64) throws(FileError) -> [UInt8]

    /// Replaces the contents, or adds to them.
    func write(_ uri: String, data: [UInt8], append: Bool) throws(FileError)

    /// Makes a file or folder named `name` in the folder `parent`, and gives
    /// its URI.
    func create(in parent: String, name: String, kind: FileKind) throws(FileError) -> String

    /// Removes a file, or a folder and all in it.
    func delete(_ uri: String) throws(FileError)
}

/// A file or folder the user gave the app, as `Files` reaches it.
public struct ContentGrant: Equatable, Sendable {

    /// The document's URI. A folder's is the document at the top of the
    /// tree the user picked, so its children's URIs can be built.
    public var uri: String

    public var kind: FileKind

    public var isWritable: Bool

    public init(uri: String, kind: FileKind, isWritable: Bool) {
        self.uri = uri
        self.kind = kind
        self.isWritable = isWritable
    }
}

/// The documents the guest holds, by the directory `Files` reaches each
/// by (`Plan.md` §6.8). Any thread.
public enum DocumentGrants {

    private static let lock = Lock()

    nonisolated(unsafe) private static var grants: [Int32: ContentGrant] = [:]

    /// The next grant's directory. A value is never used twice in a run.
    nonisolated(unsafe) private static var next = FileDirectory.firstGrant

    /// Makes `grant` a directory `Files` reaches until it's revoked.
    public static func grant(_ grant: ContentGrant) -> FileDirectory {
        lock.withLock {
            let directory = FileDirectory(rawValue: next)
            next += 1
            grants[directory.rawValue] = grant
            return directory
        }
    }

    /// Ends a grant: its directory answers `notPermitted` from here on.
    /// Operations already running finish.
    public static func revoke(_ directory: FileDirectory) {
        lock.withLock {
            grants[directory.rawValue] = nil
        }
    }

    public static func grant(for directory: Int32) -> ContentGrant? {
        lock.withLock {
            grants[directory]
        }
    }

    /// Forgets every grant, for tests.
    public static func reset() {
        lock.withLock {
            grants = [:]
        }
    }
}

/// `Files`' operations on the documents the user gave, through a
/// `ContentStore`, with `HostFiles`' rules for its grants:
///
/// - a file document is its directory's empty path, and a longer path is
///   `notDirectory`;
/// - a folder document is a directory like the app's own, its paths walked
///   by display name;
/// - the document itself can't be removed, and a released one is
///   `notPermitted`;
/// - a replacing write is truncate-and-write, since a provider has nothing
///   else.
///
/// Moves and copies are `FileEngine`'s, made of these.
struct DocumentFiles {

    /// `nil` before the host gives one: every grant is `notPermitted`, as
    /// there can be none.
    let store: (any ContentStore)?

    let maximumTransfer: Int

    /// A document or something in one.
    struct Node {
        var uri: String
        var kind: FileKind
    }

    // MARK: Operations

    func read(_ directory: Int32, _ path: String, offset: Int64, length: Int64) throws(FileError) -> [UInt8] {
        let (store, grant, components) = try open(directory, path, writing: false)
        guard offset >= 0, length >= -1 else {
            throw .unknown
        }
        guard let node = try find(store, grant, components) else {
            throw .notFound
        }
        guard node.kind == .file else {
            throw .isDirectory
        }
        let info = try store.info(node.uri)
        let available = max(info.size - offset, 0)
        let wanted = length < 0 ? available : min(length, available)
        guard wanted <= Int64(maximumTransfer) else {
            throw .tooLarge
        }
        // A provider's size can be stale, or unknown: read to the end when
        // asked to, and no more than asked otherwise.
        let bytes = try store.read(node.uri, offset: offset, length: length < 0 ? -1 : length)
        guard bytes.count <= maximumTransfer else {
            throw .tooLarge
        }
        return bytes
    }

    func write(_ directory: Int32, _ path: String, data: [UInt8], mode: Int32) throws(FileError) {
        let (store, grant, components) = try open(directory, path, writing: true)
        guard let mode = FileWriteMode(rawValue: mode) else {
            throw .unknown
        }
        guard data.count <= maximumTransfer else {
            throw .tooLarge
        }
        guard grant.kind == .directory else {
            // The file is its directory's empty path.
            try store.write(grant.uri, data: data, append: mode == .append)
            return
        }
        guard let name = components.last else {
            throw .isDirectory
        }
        let parent = try makeDirectories(store, grant, components.dropLast(), above: true)
        if let existing = try child(store, of: parent, named: name) {
            guard existing.kind == .file else {
                throw .isDirectory
            }
            try store.write(existing.uri, data: data, append: mode == .append)
        } else {
            let uri = try store.create(in: parent.uri, name: name, kind: .file)
            try store.write(uri, data: data, append: false)
        }
    }

    func list(_ directory: Int32, _ path: String) throws(FileError) -> [String] {
        let (store, grant, components) = try open(directory, path, writing: false)
        guard let node = try find(store, grant, components) else {
            throw .notFound
        }
        guard node.kind == .directory else {
            throw .notDirectory
        }
        // By their bytes, as `HostFiles` sorts them.
        return try store.children(node.uri)
            .sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
            .map { $0.kind == .directory ? $0.name + "/" : $0.name }
    }

    func attributes(_ directory: Int32, _ path: String) throws(FileError) -> FileAttributes {
        let (store, grant, components) = try open(directory, path, writing: false)
        guard let node = try find(store, grant, components) else {
            throw .notFound
        }
        let info = try store.info(node.uri)
        return FileAttributes(kind: node.kind, size: node.kind == .file ? info.size : 0, modified: info.modified)
    }

    func makeDirectory(_ directory: Int32, _ path: String) throws(FileError) {
        let (store, grant, components) = try open(directory, path, writing: true)
        guard grant.kind == .directory else {
            // Where the file is, a directory can't be.
            throw components.isEmpty ? .alreadyExists : .notDirectory
        }
        _ = try makeDirectories(store, grant, components[...], above: false)
    }

    func remove(_ directory: Int32, _ path: String) throws(FileError) {
        let (store, grant, components) = try open(directory, path, writing: true)
        guard !components.isEmpty else {
            // What the user picked stays where it is, and as it is.
            throw .invalidPath
        }
        let node: Node?
        do throws(FileError) {
            node = try find(store, grant, components)
        } catch .notFound, .notDirectory {
            // Nothing there to remove.
            return
        }
        if let node {
            try store.delete(node.uri)
        }
    }

    /// Checks `path` in `directory` as an operation would, without one.
    func check(_ directory: Int32, _ path: String, writing: Bool) throws(FileError) {
        _ = try open(directory, path, writing: writing)
    }

    /// The URI of `path` in a document, for another contract that's handed
    /// a directory and a path: a media player, an image decoder.
    func uri(of directory: Int32, path: String) throws(FileError) -> String {
        let (store, grant, components) = try open(directory, path, writing: false)
        guard let node = try find(store, grant, components) else {
            throw .notFound
        }
        return node.uri
    }

    // MARK: Paths

    /// The store, the grant, and the path's components, checked.
    private func open(_ directory: Int32, _ path: String, writing: Bool) throws(FileError) -> (any ContentStore, ContentGrant, [String]) {
        guard let grant = DocumentGrants.grant(for: directory), let store else {
            throw .notPermitted
        }
        if writing, !grant.isWritable {
            throw .readOnly
        }
        var components: [String] = []
        if !path.isEmpty {
            components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            for component in components {
                if component.isEmpty || component == "." || component == ".." || component.utf8.contains(0) {
                    throw .invalidPath
                }
            }
        }
        if grant.kind == .file, !components.isEmpty {
            throw .notDirectory
        }
        return (store, grant, components)
    }

    /// What's at `components` in the grant; `nil` when only the last is
    /// missing. A file on the way is `notDirectory`.
    private func find(_ store: any ContentStore, _ grant: ContentGrant, _ components: [String]) throws(FileError) -> Node? {
        var node = Node(uri: grant.uri, kind: grant.kind)
        for (index, name) in components.enumerated() {
            guard node.kind == .directory else {
                throw .notDirectory
            }
            guard let found = try child(store, of: node, named: name) else {
                if index == components.count - 1 {
                    return nil
                }
                throw .notFound
            }
            node = Node(uri: found.uri, kind: found.kind)
        }
        return node
    }

    private func child(_ store: any ContentStore, of folder: Node, named name: String) throws(FileError) -> ContentChild? {
        try store.children(folder.uri).first { $0.name == name }
    }

    /// Makes the folders at `components`, and gives the last. A file where
    /// one would go is `alreadyExists` for the last, and `notDirectory` on
    /// the way, or always when they're the folders `above` a new item.
    private func makeDirectories(_ store: any ContentStore, _ grant: ContentGrant, _ components: ArraySlice<String>, above: Bool) throws(FileError) -> Node {
        var node = Node(uri: grant.uri, kind: grant.kind)
        for (index, name) in zip(components.indices, components) {
            if let found = try child(store, of: node, named: name) {
                guard found.kind == .directory else {
                    throw index == components.indices.last && !above ? .alreadyExists : .notDirectory
                }
                node = Node(uri: found.uri, kind: .directory)
            } else {
                node = Node(uri: try store.create(in: node.uri, name: name, kind: .directory), kind: .directory)
            }
        }
        return node
    }
}
