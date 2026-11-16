import DynamicFiles

/// Reads the APK's assets. Any thread may call it, one call at a time.
public protocol AssetReader: Sendable {

    /// The length of the file at `path`, from the assets' root; `nil` when
    /// there's no file there.
    func length(_ path: String) -> Int64?

    /// Up to `length` bytes of the file at `path` from `offset`; `nil`
    /// when there's no file there.
    func read(_ path: String, offset: Int64, length: Int64) throws(FileError) -> [UInt8]?
}

/// What's in the bundle's resources: the packager's list of their files
/// (`assets/rt/resources.index`), since the NDK can't list an asset
/// directory's subdirectories.
///
/// The list is UTF-8, one path a line, relative to the resources, with `/`
/// between components. A directory is there when a file is in it.
public struct BundleIndex: Sendable, Equatable {

    /// Every file's path.
    public private(set) var files: Set<String> = []

    /// Each directory's entries, the empty path being the resources
    /// themselves. A directory's name ends in `/`.
    public private(set) var directories: [String: Set<String>] = ["": []]

    public init<S: Sequence>(files: S) where S.Element == String {
        for file in files {
            add(file)
        }
    }

    /// The packager's list; lines that aren't a valid path are left out.
    public init(text: [UInt8]) {
        self.init(files: text.split(separator: UInt8(ascii: "\n")).map { String(decoding: $0, as: UTF8.self) })
    }

    /// The list's text, for the packager: sorted, a line each.
    public static func text<S: Sequence>(files: S) -> String where S.Element == String {
        files.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.map { $0 + "\n" }.joined()
    }

    private mutating func add(_ path: String) {
        guard BundleIndex.isValid(path), !path.isEmpty else { return }
        let components = path.split(separator: "/").map(String.init)
        var directory = ""
        for (position, component) in components.enumerated() {
            let isLast = position == components.count - 1
            let child = directory.isEmpty ? component : directory + "/" + component
            if isLast {
                guard directories[child] == nil else { return }
                files.insert(child)
                directories[directory, default: []].insert(component)
            } else {
                guard !files.contains(child) else { return }
                directories[directory, default: []].insert(component + "/")
                if directories[child] == nil {
                    directories[child] = []
                }
            }
            directory = child
        }
    }

    /// The contract's rule for a path: plain names between `/`, no `.`,
    /// `..`, empty component or NUL. The empty path is the directory.
    public static func isValid(_ path: String) -> Bool {
        guard !path.isEmpty else { return true }
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty || component == "." || component == ".." || component.utf8.contains(0) {
                return false
            }
        }
        return true
    }

    /// Whether a file is on the way to `path`: one of the directories it's
    /// in is a file.
    public func passesThroughFile(_ path: String) -> Bool {
        var prefix = ""
        for component in path.split(separator: "/").dropLast() {
            prefix = prefix.isEmpty ? String(component) : prefix + "/" + component
            if files.contains(prefix) {
                return true
            }
        }
        return false
    }
}
