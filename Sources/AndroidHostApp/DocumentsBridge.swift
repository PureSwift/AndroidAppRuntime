import AndroidHost
import AndroidHostDocuments
import AndroidHostFiles
import DynamicFiles
import SwiftJava

/// The Kotlin `DocumentSystem` (`:appruntime-contracts`).
@JavaClass("org.pureswift.appruntime.contracts.DocumentSystem")
open class JavaDocumentSystem: JavaObject {

    @JavaMethod
    @_nonoverride public convenience init(environment: JNIEnvironment? = nil)

    @JavaMethod open func pick(_ id: Int32, _ types: [String], _ multiple: Bool, _ write: Bool) -> Bool

    @JavaMethod open func pickFolder(_ id: Int32, _ write: Bool) -> Bool

    @JavaMethod open func export(_ id: Int32, _ name: String) -> Bool

    @JavaMethod open func remember(_ uri: String, _ isDirectory: Bool, _ write: Bool) -> String

    @JavaMethod open func recall(_ key: String) -> [String]

    @JavaMethod open func forget(_ key: String)

    @JavaMethod open func error() -> Int32

    @JavaMethod open func info(_ uri: String) -> [String]

    @JavaMethod open func children(_ uri: String) -> [String]

    @JavaMethod open func read(_ uri: String, _ offset: Int64, _ length: Int64) -> [Int8]

    @JavaMethod open func write(_ uri: String, _ bytes: [Int8], _ append: Bool) -> Bool

    @JavaMethod open func create(_ parent: String, _ name: String, _ isDirectory: Bool) -> String

    @JavaMethod open func delete(_ uri: String) -> Bool
}

extension JavaDocumentSystem: DocumentPickerSystem {

    public func pick(id: Int32, types: [String], multiple: Bool, write: Bool) -> Bool {
        pick(id, types, multiple, write)
    }

    public func pickFolder(id: Int32, write: Bool) -> Bool {
        pickFolder(id, write)
    }

    public func export(id: Int32, name: String) -> Bool {
        export(id, name)
    }

    public func remember(uri: String, isDirectory: Bool, write: Bool) -> String {
        remember(uri, isDirectory, write)
    }
}

/// The documents' content through the Kotlin `DocumentSystem`, called on
/// the files queue. The Java object is made on the main thread, where its
/// class can be found, and only its methods are called from the queue.
final class AndroidContentStore: ContentStore {

    let java: JavaDocumentSystem

    init(java: JavaDocumentSystem) {
        self.java = java
    }

    /// The error the last call on this thread left.
    private func check() throws(FileError) {
        let code = java.error()
        guard code == 0 else {
            throw FileError(rawValue: code) ?? .unknown
        }
    }

    func info(_ uri: String) throws(FileError) -> ContentInfo {
        let fields = java.info(uri)
        try check()
        guard fields.count == 6 else {
            throw .unknown
        }
        let modified = Int64(fields[4]) ?? 0
        return ContentInfo(
            name: fields[0],
            contentType: fields[1].isEmpty ? nil : fields[1],
            kind: fields[2] == "1" ? .directory : .file,
            size: Int64(fields[3]) ?? 0,
            modified: modified == 0 ? nil : modified,
            isWritable: fields[5] == "1"
        )
    }

    func children(_ uri: String) throws(FileError) -> [ContentChild] {
        let fields = java.children(uri)
        try check()
        var children: [ContentChild] = []
        children.reserveCapacity(fields.count / 3)
        var index = 0
        while index + 2 < fields.count {
            children.append(ContentChild(uri: fields[index], name: fields[index + 1], kind: fields[index + 2] == "1" ? .directory : .file))
            index += 3
        }
        return children
    }

    func read(_ uri: String, offset: Int64, length: Int64) throws(FileError) -> [UInt8] {
        let bytes = java.read(uri, offset, length)
        try check()
        return bytes.map { UInt8(bitPattern: $0) }
    }

    func write(_ uri: String, data: [UInt8], append: Bool) throws(FileError) {
        _ = java.write(uri, data.map { Int8(bitPattern: $0) }, append)
        try check()
    }

    func create(in parent: String, name: String, kind: FileKind) throws(FileError) -> String {
        let uri = java.create(parent, name, kind == .directory)
        try check()
        return uri
    }

    func delete(_ uri: String) throws(FileError) {
        _ = java.delete(uri)
        try check()
    }
}

/// The Kotlin `DocumentNatives` object: pickers' results and the files the
/// app is opened with, from the Activity.
@JavaClass("org.pureswift.appruntime.contracts.DocumentNatives")
open class DocumentNatives: JavaObject {}

@JavaImplementation("org.pureswift.appruntime.contracts.DocumentNatives")
extension DocumentNatives {

    @JavaMethod
    public func picked(_ id: Int32, _ uris: [String]) {
        AndroidDocuments.didPick(id: id, uris: uris)
    }

    @JavaMethod
    public func opened(_ uris: [String], _ write: Bool) {
        AndroidDocuments.open(uris: uris, writable: write)
    }
}

enum DocumentsBridge {

    /// The Kotlin side, made on the main thread before the files are
    /// configured, and kept for as long as the app runs.
    nonisolated(unsafe) static var system: JavaDocumentSystem?

    /// The documents' content, for `AndroidFiles`.
    static func content() -> AndroidContentStore {
        let java = JavaDocumentSystem()
        system = java
        return AndroidContentStore(java: java)
    }

    /// Shows the pickers through the Kotlin side made for the files.
    static func configure() {
        AndroidDocuments.system = system
    }
}
