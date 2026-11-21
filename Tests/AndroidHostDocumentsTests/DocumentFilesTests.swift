import Foundation
import Testing
import DynamicFiles
@testable import AndroidHostFiles

/// `Files` on the documents the user gave: `FileEngine` over a provider in
/// memory, and the app's own directories in a temporary directory.
@Suite(.serialized) final class DocumentFilesTests {

    let root: URL

    let content = MemoryContent()

    let engine: FileEngine

    var granted: [FileDirectory] = []

    static let documents = FileDirectory.documents.rawValue
    static let bundle = FileDirectory.bundle.rawValue

    /// The picked folder, with `notes.txt`, `b.txt` and `sub/deep.txt`.
    let folderURI: String

    /// A picked file, apart from the folder.
    let fileURI: String

    init() throws {
        root = Foundation.FileManager.default.temporaryDirectory.appendingPathComponent("DocumentFilesTests-\(UUID().uuidString)")
        engine = try FileEngine(AndroidFiles.Configuration(
            directories: AndroidFiles.Configuration.directories(files: root.appendingPathComponent("files").path,
                                                                cache: root.appendingPathComponent("cache").path),
            assets: nil,
            content: content,
            maximumTransfer: 64
        ))
        folderURI = content.add("Notes")
        content.add("notes.txt", "first", in: folderURI)
        content.add("b.txt", "bee", in: folderURI)
        let sub = content.add("sub", in: folderURI)
        content.add("deep.txt", "deep", in: sub)
        fileURI = content.add("Letter.txt", "Dear")
    }

    deinit {
        for directory in granted {
            DocumentGrants.revoke(directory)
        }
        try? Foundation.FileManager.default.removeItem(at: root)
    }

    func grant(_ uri: String, kind: FileKind, writable: Bool = true) -> Int32 {
        let directory = DocumentGrants.grant(ContentGrant(uri: uri, kind: kind, isWritable: writable))
        granted.append(directory)
        return directory.rawValue
    }

    func text(_ outcome: FileEngine.Outcome) -> String? {
        guard case .data(let bytes) = outcome else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    func onDisk(_ path: String) -> String? {
        (try? Data(contentsOf: root.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: A file

    @Test func aFileIsItsDirectorysEmptyPath() {
        let file = grant(fileURI, kind: .file)
        #expect(file >= FileDirectory.firstGrant)
        #expect(text(engine.read(file, "", offset: 0, length: -1)) == "Dear")
        #expect(text(engine.read(file, "", offset: 1, length: 2)) == "ea")
        #expect(text(engine.read(file, "", offset: 9, length: -1)) == "")
        #expect(engine.read(file, "x", offset: 0, length: -1) == .failure(.notDirectory))
        #expect(engine.list(file, "") == .failure(.notDirectory))
        #expect(engine.attributes(file, "") == .attributes(FileAttributes(kind: .file, size: 4, modified: 1_700_000_000_000)))
        #expect(engine.write(file, "", data: Array("Dear you".utf8), mode: FileWriteMode.replace.rawValue) == .complete)
        #expect(engine.write(file, "", data: Array(",".utf8), mode: FileWriteMode.append.rawValue) == .complete)
        #expect(content.text(fileURI) == "Dear you,")
        // What the user picked stays where it is.
        #expect(engine.remove(file, "") == .failure(.invalidPath))
        #expect(engine.makeDirectory(file, "") == .failure(.alreadyExists))
        #expect(engine.makeDirectory(file, "x") == .failure(.notDirectory))
    }

    // MARK: A folder

    @Test func aFoldersPathsAreWalkedByName() {
        let folder = grant(folderURI, kind: .directory)
        #expect(engine.list(folder, "") == .names(["b.txt", "notes.txt", "sub/"]))
        #expect(engine.list(folder, "sub") == .names(["deep.txt"]))
        #expect(text(engine.read(folder, "sub/deep.txt", offset: 0, length: -1)) == "deep")
        #expect(engine.read(folder, "sub/none.txt", offset: 0, length: -1) == .failure(.notFound))
        #expect(engine.read(folder, "none/deep.txt", offset: 0, length: -1) == .failure(.notFound))
        #expect(engine.read(folder, "notes.txt/x", offset: 0, length: -1) == .failure(.notDirectory))
        #expect(engine.read(folder, "sub", offset: 0, length: -1) == .failure(.isDirectory))
        #expect(engine.list(folder, "notes.txt") == .failure(.notDirectory))
        #expect(engine.attributes(folder, "sub") == .attributes(FileAttributes(kind: .directory, size: 0, modified: 1_700_000_000_000)))
        for path in ["../x", "a//b", "./a", "sub/"] {
            #expect(engine.read(folder, path, offset: 0, length: -1) == .failure(.invalidPath), "\(path)")
        }
    }

    @Test func writesMakeTheFoldersOnTheWay() {
        let folder = grant(folderURI, kind: .directory)
        #expect(engine.write(folder, "new/deeper/c.txt", data: Array("sea".utf8), mode: FileWriteMode.replace.rawValue) == .complete)
        #expect(content.uri("new/deeper/c.txt", in: folderURI).flatMap(content.text) == "sea")
        #expect(engine.write(folder, "notes.txt", data: Array("second".utf8), mode: FileWriteMode.replace.rawValue) == .complete)
        #expect(engine.write(folder, "notes.txt", data: Array("!".utf8), mode: FileWriteMode.append.rawValue) == .complete)
        #expect(content.uri("notes.txt", in: folderURI).flatMap(content.text) == "second!")
        #expect(engine.write(folder, "", data: [], mode: 0) == .failure(.isDirectory))
        #expect(engine.write(folder, "sub", data: [], mode: 0) == .failure(.isDirectory))
        #expect(engine.write(folder, "notes.txt/x", data: [], mode: 0) == .failure(.notDirectory))
        #expect(engine.write(folder, "big", data: Array(repeating: 1, count: 65), mode: 0) == .failure(.tooLarge))
    }

    @Test func foldersAreMadeAndRemoved() {
        let folder = grant(folderURI, kind: .directory)
        #expect(engine.makeDirectory(folder, "x/y") == .complete)
        #expect(engine.makeDirectory(folder, "x/y") == .complete)
        #expect(engine.list(folder, "x") == .names(["y/"]))
        #expect(engine.makeDirectory(folder, "notes.txt") == .failure(.alreadyExists))
        #expect(engine.makeDirectory(folder, "notes.txt/z") == .failure(.notDirectory))
        #expect(engine.remove(folder, "sub") == .complete)
        #expect(content.uri("sub/deep.txt", in: folderURI) == nil)
        #expect(engine.remove(folder, "gone") == .complete)
        #expect(engine.remove(folder, "gone/too") == .complete)
        #expect(engine.remove(folder, "") == .failure(.invalidPath))
        #expect(engine.list(folder, "") == .names(["b.txt", "notes.txt", "x/"]))
    }

    // MARK: Access

    @Test func aReadOnlyDocumentIsReadOnly() {
        let folder = grant(folderURI, kind: .directory, writable: false)
        #expect(text(engine.read(folder, "notes.txt", offset: 0, length: -1)) == "first")
        #expect(engine.write(folder, "notes.txt", data: [], mode: 0) == .failure(.readOnly))
        #expect(engine.remove(folder, "notes.txt") == .failure(.readOnly))
        #expect(engine.makeDirectory(folder, "x") == .failure(.readOnly))
        #expect(engine.move(folder, "notes.txt", to: Self.documents, "n.txt") == .failure(.readOnly))
        // Copying out of it reads only.
        #expect(engine.copy(folder, "notes.txt", to: Self.documents, "n.txt") == .complete)
        #expect(onDisk("files/Documents/n.txt") == "first")
    }

    @Test func aReleasedDocumentIsNotPermitted() {
        let file = grant(fileURI, kind: .file)
        DocumentGrants.revoke(FileDirectory(rawValue: file))
        #expect(engine.read(file, "", offset: 0, length: -1) == .failure(.notPermitted))
        #expect(engine.write(file, "", data: [], mode: 0) == .failure(.notPermitted))
        // One that was never given.
        #expect(engine.list(FileDirectory.firstGrant + 100_000, "") == .failure(.notPermitted))
    }

    @Test func aProvidersErrorsReachTheGuest() {
        let file = grant(fileURI, kind: .file)
        content.unavailable = [fileURI]
        #expect(engine.read(file, "", offset: 0, length: -1) == .failure(.unavailable))
        content.unavailable = []
        _ = try? content.delete(fileURI)
        #expect(engine.read(file, "", offset: 0, length: -1) == .failure(.notFound))
    }

    @Test func aReadOverTheLimitIsTooLarge() {
        let file = grant(content.add("big.bin", String(repeating: "x", count: 100)), kind: .file)
        #expect(engine.read(file, "", offset: 0, length: -1) == .failure(.tooLarge))
        #expect(text(engine.read(file, "", offset: 50, length: -1)) == String(repeating: "x", count: 50))
    }

    // MARK: Moving and copying

    @Test func aPickedFileIsCopiedWholeButNotMoved() {
        let file = grant(fileURI, kind: .file)
        #expect(engine.copy(file, "", to: Self.documents, "letters/copy.txt") == .complete)
        #expect(onDisk("files/Documents/letters/copy.txt") == "Dear")
        #expect(engine.move(file, "", to: Self.documents, "moved.txt") == .failure(.invalidPath))
        #expect(engine.copy(file, "", to: Self.documents, "letters/copy.txt") == .failure(.alreadyExists))
        #expect(content.text(fileURI) == "Dear")
    }

    @Test func filesAndFoldersCrossBothWays() {
        let folder = grant(folderURI, kind: .directory)
        #expect(engine.write(Self.documents, "mine.txt", data: Array("mine".utf8), mode: 0) == .complete)
        #expect(engine.copy(Self.documents, "mine.txt", to: folder, "in/mine.txt") == .complete)
        #expect(content.uri("in/mine.txt", in: folderURI).flatMap(content.text) == "mine")
        // A folder, with what's in it, out and back in.
        #expect(engine.copy(folder, "sub", to: Self.documents, "sub") == .complete)
        #expect(onDisk("files/Documents/sub/deep.txt") == "deep")
        #expect(engine.move(Self.documents, "sub", to: folder, "back") == .complete)
        #expect(content.uri("back/deep.txt", in: folderURI).flatMap(content.text) == "deep")
        #expect(onDisk("files/Documents/sub/deep.txt") == nil)
        // A move out of the folder removes it there.
        #expect(engine.move(folder, "b.txt", to: Self.documents, "b.txt") == .complete)
        #expect(content.uri("b.txt", in: folderURI) == nil)
        #expect(onDisk("files/Documents/b.txt") == "bee")
        // Within the folder.
        #expect(engine.move(folder, "notes.txt", to: folder, "sub/notes.txt") == .complete)
        #expect(content.uri("sub/notes.txt", in: folderURI).flatMap(content.text) == "first")
    }

    @Test func transferFailures() {
        let folder = grant(folderURI, kind: .directory)
        #expect(engine.copy(folder, "none.txt", to: Self.documents, "x") == .failure(.notFound))
        #expect(engine.copy(folder, "notes.txt", to: folder, "b.txt") == .failure(.alreadyExists))
        #expect(engine.copy(folder, "sub", to: folder, "sub/inner") == .failure(.invalidPath))
        #expect(engine.copy(folder, "", to: Self.documents, "all") == .complete)
        #expect(engine.copy(folder, "notes.txt", to: Self.documents, "") == .failure(.invalidPath))
        #expect(engine.copy(Self.documents, "x", to: folder, "../x") == .failure(.invalidPath))
        #expect(engine.copy(folder, "notes.txt", to: Self.bundle, "x") == .failure(.readOnly))
        // A file on the way to the destination.
        #expect(engine.copy(Self.documents, "all/notes.txt", to: folder, "notes.txt/x") == .failure(.notDirectory))
    }

    // MARK: For the pickers

    @Test func anExportIsCopiedIntoTheNewDocument() throws {
        let created = content.add("Saved.txt", "")
        // Over one chunk (64 bytes here), so it's copied in two.
        #expect(engine.write(Self.documents, "draft.txt", data: Array(String(repeating: "ab", count: 25).utf8), mode: 0) == .complete)
        #expect(engine.write(Self.documents, "draft.txt", data: Array(String(repeating: "ab", count: 25).utf8), mode: 1) == .complete)
        try engine.export(Self.documents, "draft.txt", to: created)
        #expect(content.text(created) == String(repeating: "ab", count: 50))
        #expect(throws: FileError.isDirectory) { try self.engine.checkExport(Self.documents, "") }
        #expect(throws: FileError.notFound) { try self.engine.checkExport(Self.documents, "none") }
        let described = engine.describe([created, "content://memory/none"])
        #expect(try described[0].get().name == "Saved.txt")
        #expect(throws: FileError.notFound) { try described[1].get() }
    }

    @Test func anotherContractFindsADocumentsURI() throws {
        let folder = grant(folderURI, kind: .directory)
        #expect(try engine.documents.uri(of: folder, path: "sub/deep.txt") == content.uri("sub/deep.txt", in: folderURI))
        #expect(throws: FileError.notFound) { try self.engine.documents.uri(of: folder, path: "none") }
    }
}
