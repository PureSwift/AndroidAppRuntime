import Foundation
import Testing
import DynamicDocuments
import DynamicFiles
@testable import AndroidHostDocuments
@testable import AndroidHostFiles

/// The pickers as the Kotlin side shows them: what was asked, and what to
/// answer.
final class ScriptedPickers: DocumentPickerSystem {

    var calls: [String] = []

    /// Whether there's an Activity to show a picker from.
    var canShow = true

    /// The last picker's id.
    var lastID: Int32 = -1

    var rememberAnswer = "key-1"

    var kept: [String: [String]] = [:]

    func pick(id: Int32, types: [String], multiple: Bool, write: Bool) -> Bool {
        lastID = id
        calls.append("pick \(types) multiple:\(multiple) write:\(write)")
        return canShow
    }

    func pickPhotos(id: Int32, kinds: Int32, multiple: Bool) -> Bool {
        lastID = id
        calls.append("pickPhotos kinds:\(kinds) multiple:\(multiple)")
        return canShow
    }

    func pickFolder(id: Int32, write: Bool) -> Bool {
        lastID = id
        calls.append("pickFolder write:\(write)")
        return canShow
    }

    func export(id: Int32, name: String) -> Bool {
        lastID = id
        calls.append("export \(name)")
        return canShow
    }

    func remember(uri: String, isDirectory: Bool, write: Bool) -> String {
        calls.append("remember \(uri) directory:\(isDirectory) write:\(write)")
        return rememberAnswer
    }

    func recall(_ key: String) -> [String] {
        kept[key] ?? []
    }

    func forget(_ key: String) {
        calls.append("forget \(key)")
    }
}

/// One operation's answer.
final class Answer: DocumentCallback {

    enum Value: Equatable {
        case picked(Int)
        case complete
        case bookmark(String)
        case failed(DocumentError)
    }

    var value: Value?

    var grants: [any DocumentGrant] = []

    func didPick(_ documents: [any DocumentGrant]) {
        value = .picked(documents.count)
        grants = documents
    }

    func didComplete() {
        value = .complete
    }

    func didBookmark(_ bookmark: String) {
        value = .bookmark(bookmark)
    }

    func didFail(_ error: Int32) {
        value = .failed(DocumentError(rawValue: error) ?? .unknown)
    }
}

final class Listener: DocumentsDelegate {

    var opened: [[any DocumentGrant]] = []

    func didOpen(_ documents: [any DocumentGrant]) {
        opened.append(documents)
    }
}

/// `AndroidDocuments` over scripted pickers, a provider in memory, and
/// files that run their work inline. Answers wait in `jobs` until `run()`,
/// as they wait for the main looper on a device.
///
/// Serialized: `AndroidDocuments` is shared.
@Suite(.serialized) @MainActor final class AndroidDocumentsTests {

    let root: URL

    let content = MemoryContent()

    let pickers = ScriptedPickers()

    let files: AndroidFiles

    nonisolated(unsafe) static var jobs: [@Sendable () -> Void] = []

    let picked: String

    let folder: String

    init() throws {
        root = Foundation.FileManager.default.temporaryDirectory.appendingPathComponent("AndroidDocumentsTests-\(UUID().uuidString)")
        let configuration = AndroidFiles.Configuration(
            directories: AndroidFiles.Configuration.directories(files: root.appendingPathComponent("files").path,
                                                                cache: root.appendingPathComponent("cache").path),
            assets: nil,
            content: content,
            work: { $0() },
            deliver: { job in AndroidDocumentsTests.jobs.append(job) }
        )
        files = AndroidFiles(engine: try FileEngine(configuration), configuration: configuration)
        picked = content.add("Letter.txt", "Dear")
        folder = content.add("Notes")
        content.add("a.txt", "a", in: folder)
        Self.jobs = []
        AndroidDocuments.reset()
        AndroidDocuments.system = pickers
        AndroidDocuments.deliver = { job in AndroidDocumentsTests.jobs.append(job) }
        let files = files
        AndroidDocuments.files = { files }
    }

    deinit {
        try? Foundation.FileManager.default.removeItem(at: root)
    }

    /// Runs the answers waiting, and those they post.
    func run() {
        while !Self.jobs.isEmpty {
            Self.jobs.removeFirst()()
        }
    }

    var documents: AndroidDocuments {
        AndroidDocuments.shared()
    }

    func text(_ directory: Int32, _ path: String = "") -> String? {
        guard case .data(let bytes) = files.engine.read(directory, path, offset: 0, length: -1) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: Pickers

    @Test func withoutTheKotlinSidePickersAreUnsupported() {
        AndroidDocuments.system = nil
        let answer = Answer()
        documents.pick([], multiple: false, access: 0, callback: answer)
        #expect(answer.value == nil)
        run()
        #expect(answer.value == .failed(.unsupported))
    }

    @Test func aPickedFileIsGranted() {
        let answer = Answer()
        documents.pick(["text/plain", ".md"], multiple: false, access: DocumentAccess.readWrite.rawValue, callback: answer)
        #expect(pickers.calls == [#"pick ["text/plain", ".md"] multiple:false write:true"#])
        AndroidDocuments.didPick(id: pickers.lastID, uris: [picked])
        run()
        #expect(answer.value == .picked(1))
        #expect(answer.grants[0].name() == "Letter.txt")
        #expect(answer.grants[0].kind() == FileKind.file.rawValue)
        #expect(answer.grants[0].contentType() == "text/plain")
        #expect(answer.grants[0].isWritable())
        let directory = answer.grants[0].directory()
        #expect(directory >= DocumentGrants.firstDirectory)
        #expect(text(directory) == "Dear")
        // Letting go ends the access.
        answer.grants = []
        #expect(files.engine.read(directory, "", offset: 0, length: -1) == .failure(.notPermitted))
    }

    @Test func readAccessIsReadOnlyEvenWhereTheProviderWrites() {
        let answer = Answer()
        documents.pick([], multiple: false, access: DocumentAccess.read.rawValue, callback: answer)
        AndroidDocuments.didPick(id: pickers.lastID, uris: [picked])
        run()
        #expect(answer.grants.first?.isWritable() == false)
        #expect(files.engine.write(answer.grants[0].directory(), "", data: [], mode: 0) == .failure(.readOnly))
    }

    @Test func onePickerAtATime() {
        let first = Answer()
        let second = Answer()
        documents.pick([], multiple: false, access: 0, callback: first)
        documents.pickFolder(0, callback: second)
        run()
        #expect(second.value == .failed(.busy))
        #expect(first.value == nil)
        // A result for another picker is dropped.
        AndroidDocuments.didPick(id: pickers.lastID + 1, uris: [picked])
        run()
        #expect(first.value == nil)
        AndroidDocuments.didPick(id: pickers.lastID, uris: [])
        run()
        #expect(first.value == .picked(0))
        let third = Answer()
        documents.pick([], multiple: false, access: 0, callback: third)
        #expect(pickers.calls.count == 2)
    }

    @Test func withoutAnActivityAPickerIsNotAllowed() {
        pickers.canShow = false
        let answer = Answer()
        documents.pick([], multiple: false, access: 0, callback: answer)
        run()
        #expect(answer.value == .failed(.notAllowed))
        pickers.canShow = true
        let again = Answer()
        documents.pick([], multiple: false, access: 0, callback: again)
        AndroidDocuments.didPick(id: pickers.lastID, uris: [picked])
        run()
        #expect(again.value == .picked(1))
    }

    @Test func aPickerForOneGivesOne() {
        let one = Answer()
        documents.pick([], multiple: false, access: 0, callback: one)
        AndroidDocuments.didPick(id: pickers.lastID, uris: [picked, folder])
        run()
        #expect(one.value == .picked(1))
        let several = Answer()
        documents.pick([], multiple: true, access: 0, callback: several)
        AndroidDocuments.didPick(id: pickers.lastID, uris: [picked, picked])
        run()
        #expect(several.value == .picked(2))
        #expect(several.grants[0].directory() != several.grants[1].directory())
    }

    @Test func aPickedFolderIsListed() {
        let answer = Answer()
        documents.pickFolder(DocumentAccess.readWrite.rawValue, callback: answer)
        #expect(pickers.calls == ["pickFolder write:true"])
        AndroidDocuments.didPick(id: pickers.lastID, uris: [folder])
        run()
        let grant = answer.grants[0]
        #expect(grant.kind() == FileKind.directory.rawValue)
        #expect(grant.contentType() == nil)
        #expect(files.engine.list(grant.directory(), "") == .names(["a.txt"]))
    }

    @Test func aDocumentThatsGoneIsNotFound() {
        let answer = Answer()
        documents.pick([], multiple: false, access: 0, callback: answer)
        AndroidDocuments.didPick(id: pickers.lastID, uris: ["content://memory/none"])
        run()
        #expect(answer.value == .failed(.notFound))
    }

    @Test func photosAreReadOnlyAndArentBookmarked() {
        let photo = content.add("IMG_0001.jpg", "jpeg")
        let video = content.add("VID_0002.mp4", "mp4")
        let answer = Answer()
        documents.pickPhotos(1, multiple: true, callback: answer)
        #expect(pickers.calls == ["pickPhotos kinds:1 multiple:true"])
        AndroidDocuments.didPick(id: pickers.lastID, uris: [photo, video])
        run()
        #expect(answer.value == .picked(2))
        #expect(answer.grants.map { $0.name() } == ["IMG_0001.jpg", "VID_0002.mp4"])
        // The provider writes, but a photo is read-only.
        #expect(answer.grants.allSatisfy { !$0.isWritable() })
        let directory = answer.grants[0].directory()
        #expect(text(directory) == "jpeg")
        #expect(files.engine.write(directory, "", data: [], mode: 0) == .failure(.readOnly))
        let bookmark = Answer()
        answer.grants[0].bookmark(bookmark)
        run()
        #expect(bookmark.value == .failed(.unsupported))
        #expect(pickers.calls.count == 1)
    }

    @Test func thePhotoPickerForOneGivesOneOrNone() {
        let photo = content.add("IMG_0001.jpg", "jpeg")
        let one = Answer()
        documents.pickPhotos(0, multiple: false, callback: one)
        #expect(pickers.calls == ["pickPhotos kinds:0 multiple:false"])
        AndroidDocuments.didPick(id: pickers.lastID, uris: [photo, picked])
        run()
        #expect(one.value == .picked(1))
        let cancelled = Answer()
        documents.pickPhotos(2, multiple: false, callback: cancelled)
        AndroidDocuments.didPick(id: pickers.lastID, uris: [])
        run()
        #expect(cancelled.value == .picked(0))
        // Busy and without an Activity, as the other pickers.
        let first = Answer()
        let second = Answer()
        documents.pickPhotos(0, multiple: false, callback: first)
        documents.pickPhotos(0, multiple: false, callback: second)
        run()
        #expect(second.value == .failed(.busy))
        AndroidDocuments.didPick(id: pickers.lastID, uris: [])
        pickers.canShow = false
        let none = Answer()
        documents.pickPhotos(0, multiple: false, callback: none)
        run()
        #expect(none.value == .failed(.notAllowed))
    }

    // MARK: Saving

    @Test func anExportCopiesTheFileIntoTheNewDocument() {
        #expect(files.engine.write(FileDirectory.temporary.rawValue, "Untitled.txt", data: Array("draft".utf8), mode: 0) == .complete)
        let answer = Answer()
        documents.export(FileDirectory.temporary.rawValue, path: "Untitled.txt", name: "Notes.txt", callback: answer)
        run()
        #expect(pickers.calls == ["export Notes.txt"])
        let created = content.add("Notes.txt", "")
        AndroidDocuments.didPick(id: pickers.lastID, uris: [created])
        run()
        #expect(answer.value == .picked(1))
        #expect(content.text(created) == "draft")
        #expect(answer.grants[0].isWritable())
        #expect(answer.grants[0].name() == "Notes.txt")
    }

    @Test func anExportsSourceIsCheckedFirst() {
        let missing = Answer()
        documents.export(FileDirectory.temporary.rawValue, path: "none.txt", name: "x", callback: missing)
        run()
        #expect(missing.value == .failed(.notFound))
        let folder = Answer()
        documents.export(FileDirectory.temporary.rawValue, path: "", name: "x", callback: folder)
        run()
        #expect(folder.value == .failed(.notFound))
        #expect(pickers.calls.isEmpty)
        // Cancelled.
        #expect(files.engine.write(FileDirectory.temporary.rawValue, "a.txt", data: [], mode: 0) == .complete)
        let cancelled = Answer()
        documents.export(FileDirectory.temporary.rawValue, path: "a.txt", name: "a.txt", callback: cancelled)
        run()
        AndroidDocuments.didPick(id: pickers.lastID, uris: [])
        run()
        #expect(cancelled.value == .picked(0))
    }

    // MARK: Bookmarks

    @Test func bookmarksAreKeptAndResolved() {
        let answer = Answer()
        documents.pick([], multiple: false, access: DocumentAccess.readWrite.rawValue, callback: answer)
        AndroidDocuments.didPick(id: pickers.lastID, uris: [picked])
        run()
        let bookmark = Answer()
        answer.grants[0].bookmark(bookmark)
        run()
        #expect(bookmark.value == .bookmark("key-1"))
        #expect(pickers.calls.last == "remember \(picked) directory:false write:true")

        pickers.kept["key-1"] = [picked, "0", "1"]
        let resolved = Answer()
        documents.resolve("key-1", callback: resolved)
        run()
        #expect(resolved.value == .picked(1))
        #expect(resolved.grants[0].isWritable())
        #expect(text(resolved.grants[0].directory()) == "Dear")

        documents.forget("key-1")
        #expect(pickers.calls.last == "forget key-1")
    }

    @Test func bookmarksThatCantBeKeptOrResolved() {
        let answer = Answer()
        documents.pick([], multiple: false, access: 0, callback: answer)
        AndroidDocuments.didPick(id: pickers.lastID, uris: [picked])
        run()
        pickers.rememberAnswer = ""
        let unsupported = Answer()
        answer.grants[0].bookmark(unsupported)
        run()
        #expect(unsupported.value == .failed(.unsupported))
        pickers.rememberAnswer = "-"
        let full = Answer()
        answer.grants[0].bookmark(full)
        run()
        #expect(full.value == .failed(.limitReached))

        let unknown = Answer()
        documents.resolve("none", callback: unknown)
        run()
        #expect(unknown.value == .failed(.notFound))
        pickers.kept["taken"] = [picked]
        let taken = Answer()
        documents.resolve("taken", callback: taken)
        run()
        #expect(taken.value == .failed(.notPermitted))
        pickers.kept["gone"] = ["content://memory/none", "0", "1"]
        let gone = Answer()
        documents.resolve("gone", callback: gone)
        run()
        #expect(gone.value == .failed(.notFound))
    }

    // MARK: Opened with

    @Test func filesTheAppIsOpenedWithWaitForTheGuest() {
        AndroidDocuments.open(uris: [picked], writable: true)
        run()
        let listener = Listener()
        documents.setDelegate(listener)
        #expect(listener.opened.isEmpty)
        run()
        #expect(listener.opened.count == 1)
        #expect(listener.opened[0][0].name() == "Letter.txt")
        #expect(listener.opened[0][0].isWritable())
        // While it listens, they come at once.
        AndroidDocuments.open(uris: [folder], writable: false)
        run()
        #expect(listener.opened.count == 2)
        #expect(listener.opened[1][0].isWritable() == false)
        // Nothing waits twice.
        documents.setDelegate(nil)
        documents.setDelegate(listener)
        run()
        #expect(listener.opened.count == 2)
    }
}
