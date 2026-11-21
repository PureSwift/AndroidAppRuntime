import DynamicFiles
@testable import AndroidHostFiles

/// A provider's documents in memory, by URI, as the Storage Access
/// Framework gives them: a folder's children are found by listing it.
final class MemoryContent: ContentStore {

    final class Node {
        var name: String
        var kind: FileKind
        var data: [UInt8]
        var children: [String] = []
        var parent: String?
        var isWritable = true
        var contentType: String?

        init(name: String, kind: FileKind, data: [UInt8], parent: String?) {
            self.name = name
            self.kind = kind
            self.data = data
            self.parent = parent
        }
    }

    private(set) var nodes: [String: Node] = [:]

    private var next = 0

    /// URIs the provider can't supply now.
    var unavailable: Set<String> = []

    /// Each call, as `name uri`.
    private(set) var calls: [String] = []

    /// Adds a document, in `parent` when given, and gives its URI.
    @discardableResult
    func add(_ name: String, _ text: String? = nil, in parent: String? = nil) -> String {
        next += 1
        let uri = "content://memory/\(next)"
        let node = Node(name: name, kind: text == nil ? .directory : .file, data: Array((text ?? "").utf8), parent: parent)
        node.contentType = text == nil ? nil : "text/plain"
        nodes[uri] = node
        if let parent {
            nodes[parent]?.children.append(uri)
        }
        return uri
    }

    /// The text at `uri`, or `nil` if there's nothing.
    func text(_ uri: String) -> String? {
        nodes[uri].map { String(decoding: $0.data, as: UTF8.self) }
    }

    /// The URI of `path`, walked by name from `root`.
    func uri(_ path: String, in root: String) -> String? {
        var current = root
        for name in path.split(separator: "/") {
            guard let found = nodes[current]?.children.first(where: { nodes[$0]?.name == String(name) }) else { return nil }
            current = found
        }
        return current
    }

    private func node(_ uri: String) throws(FileError) -> Node {
        guard !unavailable.contains(uri) else {
            throw .unavailable
        }
        guard let node = nodes[uri] else {
            throw .notFound
        }
        return node
    }

    func info(_ uri: String) throws(FileError) -> ContentInfo {
        calls.append("info \(uri)")
        let node = try node(uri)
        return ContentInfo(name: node.name, contentType: node.contentType, kind: node.kind,
                           size: node.kind == .file ? Int64(node.data.count) : 0, modified: 1_700_000_000_000,
                           isWritable: node.isWritable)
    }

    func children(_ uri: String) throws(FileError) -> [ContentChild] {
        calls.append("children \(uri)")
        let node = try node(uri)
        return node.children.compactMap { child in
            nodes[child].map { ContentChild(uri: child, name: $0.name, kind: $0.kind) }
        }
    }

    func read(_ uri: String, offset: Int64, length: Int64) throws(FileError) -> [UInt8] {
        calls.append("read \(uri)")
        let node = try node(uri)
        let start = min(Int(offset), node.data.count)
        let end = length < 0 ? node.data.count : min(start + Int(length), node.data.count)
        return Array(node.data[start..<end])
    }

    func write(_ uri: String, data: [UInt8], append: Bool) throws(FileError) {
        calls.append("write \(uri)")
        let node = try node(uri)
        guard node.isWritable else {
            throw .readOnly
        }
        node.data = append ? node.data + data : data
    }

    func create(in parent: String, name: String, kind: FileKind) throws(FileError) -> String {
        calls.append("create \(name)")
        let folder = try node(parent)
        guard folder.isWritable else {
            throw .readOnly
        }
        return add(name, kind == .file ? "" : nil, in: parent)
    }

    func delete(_ uri: String) throws(FileError) {
        calls.append("delete \(uri)")
        let node = try node(uri)
        for child in node.children {
            try delete(child)
        }
        nodes[uri] = nil
        if let parent = node.parent {
            nodes[parent]?.children.removeAll { $0 == uri }
        }
    }
}
