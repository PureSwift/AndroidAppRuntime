import Foundation
import Testing
import AndroidHost
import DynamicFiles
@testable import AndroidHostFiles

/// The APK's assets, in memory: a file per path, and no directories, as the
/// NDK has it.
struct MemoryAssets: AssetReader {

    var files: [String: [UInt8]]

    /// Resources at `rt/resources/…`, and their index beside them.
    init(resources: [String: String], index: [String]? = nil) {
        var files: [String: [UInt8]] = [:]
        for (path, text) in resources {
            files["rt/resources/" + path] = Array(text.utf8)
        }
        files["rt/resources.index"] = Array(BundleIndex.text(files: index ?? Array(resources.keys)).utf8)
        self.files = files
    }

    func length(_ path: String) -> Int64? {
        files[path].map { Int64($0.count) }
    }

    func read(_ path: String, offset: Int64, length: Int64) throws(FileError) -> [UInt8]? {
        guard let file = files[path] else { return nil }
        let start = min(Int(offset), file.count)
        return Array(file[start..<min(start + Int(length), file.count)])
    }
}

@Suite struct BundleIndexTests {

    @Test func directoriesComeFromTheFilesInThem() {
        let index = BundleIndex(files: ["welcome.txt", "levels/1.map", "levels/2.map", "levels/boss/3.map"])
        #expect(index.files == ["welcome.txt", "levels/1.map", "levels/2.map", "levels/boss/3.map"])
        #expect(index.directories[""] == ["welcome.txt", "levels/"])
        #expect(index.directories["levels"] == ["1.map", "2.map", "boss/"])
        #expect(index.directories["levels/boss"] == ["3.map"])
        #expect(index.directories["welcome.txt"] == nil)
    }

    @Test func linesThatArentPathsAreLeftOut() {
        let text = "a.txt\n\n/abs\n../up\nb//c\nd/./e\nok/f.txt\n"
        let index = BundleIndex(text: Array(text.utf8))
        #expect(index.files == ["a.txt", "ok/f.txt"])
    }

    @Test func aNameIsAFileOrADirectoryNotBoth() {
        let index = BundleIndex(files: ["a", "a/b", "c/d", "c"])
        #expect(index.files == ["a", "c/d"])
        #expect(index.directories["a"] == nil)
        #expect(index.directories["c"] == ["d"])
    }

    @Test func aFileOnTheWay() {
        let index = BundleIndex(files: ["welcome.txt", "levels/1.map"])
        #expect(index.passesThroughFile("welcome.txt/x"))
        #expect(index.passesThroughFile("welcome.txt/x/y"))
        #expect(!index.passesThroughFile("levels/1.map"))
        #expect(!index.passesThroughFile("levels/9.map"))
    }

    @Test func theTextIsSortedByBytes() {
        #expect(BundleIndex.text(files: ["b", "B", "a/c", "é"]) == "B\na/c\nb\né\n")
    }

    @Test func validPaths() {
        #expect(BundleIndex.isValid(""))
        #expect(BundleIndex.isValid("a/b.c"))
        #expect(BundleIndex.isValid(".hidden"))
        for path in ["/a", "a/", "a//b", ".", "..", "a/../b", "a\u{0}b"] {
            #expect(!BundleIndex.isValid(path), "\(path)")
        }
    }
}

/// `AndroidFiles` against real files in a temporary directory and assets in
/// memory.
///
/// Serialized: `HostFiles.configure`, which the engine uses, is shared.
@Suite(.serialized) final class AndroidFilesTests {

    let root: URL

    let engine: FileEngine

    static let documents = FileDirectory.documents.rawValue
    static let data = FileDirectory.data.rawValue
    static let caches = FileDirectory.caches.rawValue
    static let temporary = FileDirectory.temporary.rawValue
    static let bundle = FileDirectory.bundle.rawValue

    static let resources = [
        "welcome.txt": "Welcome to the notebook.",
        "levels/1.map": "LEVEL ONE",
        "levels/boss/3.map": "BOSS",
        ".hidden": "dot",
        "big.bin": String(repeating: "0123456789", count: 30),
    ]

    init() throws {
        root = Foundation.FileManager.default.temporaryDirectory.appendingPathComponent("AndroidFilesTests-\(UUID().uuidString)")
        // Something left in `temporary` from the last run.
        let leftover = root.appendingPathComponent("cache/tmp/old")
        try Foundation.FileManager.default.createDirectory(at: leftover.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: leftover)
        let configuration = AndroidFiles.Configuration(
            directories: Self.directories(root),
            assets: MemoryAssets(resources: Self.resources),
            maximumTransfer: 128
        )
        engine = try FileEngine(configuration)
    }

    deinit {
        try? Foundation.FileManager.default.removeItem(at: root)
    }

    static func directories(_ root: URL) -> [FileDirectory: String] {
        AndroidFiles.Configuration.directories(files: root.appendingPathComponent("files").path,
                                               cache: root.appendingPathComponent("cache").path)
    }

    func onDisk(_ path: String) -> String? {
        (try? Data(contentsOf: root.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
    }

    func exists(_ path: String) -> Bool {
        Foundation.FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    // MARK: Directories

    @Test func theDirectoriesAreUnderFilesDirAndCacheDir() {
        let directories = AndroidFiles.Configuration.directories(files: "/data/user/0/app/files", cache: "/data/user/0/app/cache")
        #expect(directories == [
            .documents: "/data/user/0/app/files/Documents",
            .data: "/data/user/0/app/files/Data",
            .caches: "/data/user/0/app/cache/Caches",
            .temporary: "/data/user/0/app/cache/tmp",
        ])
    }

    @Test func configuringMakesTheDirectoriesAndEmptiesTemporary() {
        for path in ["files/Documents", "files/Data", "cache/Caches", "cache/tmp"] {
            #expect(exists(path), "\(path)")
        }
        #expect(!exists("cache/tmp/old"))
    }

    @Test func aBundleDirectoryGivenIsLeftOut() {
        let configuration = AndroidFiles.Configuration(directories: [.bundle: "/somewhere", .documents: "/d"], assets: nil)
        #expect(configuration.directories == [.documents: "/d"])
    }

    // MARK: The bundle

    @Test func readsBundleFilesWholeAndInRanges() {
        #expect(engine.read(Self.bundle, "welcome.txt", offset: 0, length: -1) == .data(Array("Welcome to the notebook.".utf8)))
        #expect(engine.read(Self.bundle, "levels/1.map", offset: 6, length: 3) == .data(Array("ONE".utf8)))
        #expect(engine.read(Self.bundle, "levels/1.map", offset: 6, length: 100) == .data(Array("ONE".utf8)))
        #expect(engine.read(Self.bundle, "levels/1.map", offset: 9, length: -1) == .data([]), "at the end")
        #expect(engine.read(Self.bundle, "levels/1.map", offset: 50, length: 4) == .data([]), "past the end")
        #expect(engine.read(Self.bundle, ".hidden", offset: 0, length: -1) == .data(Array("dot".utf8)))
    }

    @Test func bundleReadFailures() {
        #expect(engine.read(Self.bundle, "levels", offset: 0, length: -1) == .failure(.isDirectory))
        #expect(engine.read(Self.bundle, "", offset: 0, length: -1) == .failure(.isDirectory))
        #expect(engine.read(Self.bundle, "missing.txt", offset: 0, length: -1) == .failure(.notFound))
        #expect(engine.read(Self.bundle, "welcome.txt/x", offset: 0, length: -1) == .failure(.notDirectory))
        #expect(engine.read(Self.bundle, "../etc/passwd", offset: 0, length: -1) == .failure(.invalidPath))
        #expect(engine.read(Self.bundle, "/welcome.txt", offset: 0, length: -1) == .failure(.invalidPath))
        #expect(engine.read(Self.bundle, "big.bin", offset: 0, length: -1) == .failure(.tooLarge))
        #expect(engine.read(Self.bundle, "big.bin", offset: 0, length: 100) == .data(Array(String(repeating: "0123456789", count: 10).utf8)))
    }

    @Test func listsTheBundle() {
        #expect(engine.list(Self.bundle, "") == .names([".hidden", "big.bin", "levels/", "welcome.txt"]))
        #expect(engine.list(Self.bundle, "levels") == .names(["1.map", "boss/"]))
        #expect(engine.list(Self.bundle, "welcome.txt") == .failure(.notDirectory))
        #expect(engine.list(Self.bundle, "nothing") == .failure(.notFound))
    }

    @Test func bundleAttributes() {
        #expect(engine.attributes(Self.bundle, "welcome.txt") == .attributes(FileAttributes(kind: .file, size: 24, modified: nil)))
        #expect(engine.attributes(Self.bundle, "levels/boss") == .attributes(FileAttributes(kind: .directory, size: 0, modified: nil)))
        #expect(engine.attributes(Self.bundle, "") == .attributes(FileAttributes(kind: .directory, size: 0, modified: nil)))
        #expect(engine.attributes(Self.bundle, "nothing") == .failure(.notFound))
    }

    @Test func aFileInTheIndexWithoutAnAssetIsntThere() throws {
        // The index can't name a file the APK doesn't have, but if it did:
        let assets = MemoryAssets(resources: ["a.txt": "A"], index: ["a.txt", "gone.txt"])
        let engine = try FileEngine(AndroidFiles.Configuration(directories: [:], assets: assets))
        #expect(engine.list(Self.bundle, "") == .names(["a.txt", "gone.txt"]))
        #expect(engine.read(Self.bundle, "gone.txt", offset: 0, length: -1) == .failure(.notFound))
    }

    @Test func withoutAssetsTheBundleIsEmpty() throws {
        let engine = try FileEngine(AndroidFiles.Configuration(directories: [:], assets: nil))
        #expect(engine.list(Self.bundle, "") == .names([]))
        #expect(engine.read(Self.bundle, "welcome.txt", offset: 0, length: -1) == .failure(.notFound))
    }

    @Test func theBundleIsReadOnly() {
        #expect(engine.write(Self.bundle, "new.txt", data: [1], mode: 0) == .failure(.readOnly))
        #expect(engine.write(Self.bundle, "welcome.txt", data: [1], mode: 1) == .failure(.readOnly))
        #expect(engine.makeDirectory(Self.bundle, "new") == .failure(.readOnly))
        #expect(engine.remove(Self.bundle, "welcome.txt") == .failure(.readOnly))
        #expect(engine.remove(Self.bundle, "") == .failure(.readOnly))
        #expect(engine.move(Self.bundle, "welcome.txt", to: Self.documents, "w.txt") == .failure(.readOnly))
        #expect(engine.write(Self.documents, "x.txt", data: [1], mode: 0) == .complete)
        #expect(engine.move(Self.documents, "x.txt", to: Self.bundle, "x.txt") == .failure(.readOnly))
        #expect(engine.copy(Self.documents, "x.txt", to: Self.bundle, "x.txt") == .failure(.readOnly))
        #expect(engine.copy(Self.bundle, "welcome.txt", to: Self.bundle, "copy.txt") == .failure(.readOnly))
    }

    // MARK: Copying out of the bundle

    @Test func copiesAFileOutOfTheBundle() {
        #expect(engine.copy(Self.bundle, "welcome.txt", to: Self.documents, "notes/welcome.txt") == .complete)
        #expect(onDisk("files/Documents/notes/welcome.txt") == "Welcome to the notebook.")
    }

    @Test func copiesALargeFileInChunks() {
        // Larger than one transfer (128 bytes here), which a copy isn't held to.
        #expect(engine.copy(Self.bundle, "big.bin", to: Self.caches, "big.bin") == .complete)
        #expect(onDisk("cache/Caches/big.bin") == String(repeating: "0123456789", count: 30))
    }

    @Test func copiesADirectoryOutOfTheBundle() {
        #expect(engine.copy(Self.bundle, "levels", to: Self.data, "saved/levels") == .complete)
        #expect(onDisk("files/Data/saved/levels/1.map") == "LEVEL ONE")
        #expect(onDisk("files/Data/saved/levels/boss/3.map") == "BOSS")
        #expect(engine.list(FileDirectory.data.rawValue, "saved/levels") == .names(["1.map", "boss/"]))
    }

    @Test func copyOutOfTheBundleFailures() {
        #expect(engine.write(Self.documents, "taken.txt", data: [1], mode: 0) == .complete)
        #expect(engine.copy(Self.bundle, "welcome.txt", to: Self.documents, "taken.txt") == .failure(.alreadyExists))
        #expect(onDisk("files/Documents/taken.txt") == "\u{1}", "the file in the way is kept")
        #expect(engine.copy(Self.bundle, "missing.txt", to: Self.documents, "m.txt") == .failure(.notFound))
        #expect(engine.copy(Self.bundle, "", to: Self.documents, "all") == .failure(.invalidPath))
        #expect(engine.copy(Self.bundle, "welcome.txt", to: Self.documents, "") == .failure(.invalidPath))
        #expect(engine.copy(Self.bundle, "welcome.txt", to: Self.documents, "a/../b") == .failure(.invalidPath))
        #expect(engine.copy(Self.bundle, "welcome.txt", to: 42, "w.txt") == .failure(.invalidPath))
        // A file where a directory is needed on the way.
        #expect(engine.copy(Self.bundle, "levels", to: Self.documents, "taken.txt/levels") == .failure(.notDirectory))
        #expect(engine.copy(Self.bundle, "welcome.txt", to: Self.documents, "taken.txt/w.txt") == .failure(.notDirectory))
        #expect(engine.list(Self.documents, "") == .names(["taken.txt"]), "nothing half-copied")
    }

    // MARK: The writable directories

    @Test func theWritableDirectoriesAreHostFiles() {
        #expect(engine.write(Self.documents, "saves/slot1.sav", data: Array("one".utf8), mode: 0) == .complete)
        #expect(engine.write(Self.documents, "saves/slot1.sav", data: Array("+two".utf8), mode: 1) == .complete)
        #expect(onDisk("files/Documents/saves/slot1.sav") == "one+two")
        #expect(engine.read(Self.documents, "saves/slot1.sav", offset: 3, length: -1) == .data(Array("+two".utf8)))
        #expect(engine.list(Self.documents, "") == .names(["saves/"]))
        guard case .attributes(let attributes) = engine.attributes(Self.documents, "saves/slot1.sav") else {
            Issue.record("no attributes")
            return
        }
        #expect(attributes.kind == .file && attributes.size == 7 && attributes.modified != nil)
        #expect(engine.move(Self.documents, "saves", to: Self.temporary, "old-saves") == .complete)
        #expect(onDisk("cache/tmp/old-saves/slot1.sav") == "one+two")
        #expect(engine.copy(Self.temporary, "old-saves", to: Self.caches, "s") == .complete)
        #expect(engine.remove(Self.temporary, "") == .complete)
        #expect(engine.list(Self.temporary, "") == .names([]))
        #expect(engine.read(Self.caches, "s/slot1.sav", offset: 0, length: -1) == .data(Array("one+two".utf8)))
        #expect(engine.read(Self.documents, "../escape", offset: 0, length: -1) == .failure(.invalidPath))
    }

    // MARK: Through the contract

    /// Records each answer, in order.
    final class Recorder: FileCallback {

        nonisolated(unsafe) static var answers: [String] = []

        let name: String

        init(_ name: String) {
            self.name = name
        }

        func didComplete() { Self.answers.append("\(name): complete") }
        func didRead(_ data: [UInt8]) { Self.answers.append("\(name): \(String(decoding: data, as: UTF8.self))") }
        func didList(_ names: [String]) { Self.answers.append("\(name): \(names)") }
        func didGetAttributes(kind: Int32, size: Int64, modified: Int64) { Self.answers.append("\(name): \(kind) \(size) \(modified)") }
        func didFail(_ error: Int32) { Self.answers.append("\(name): error \(error)") }
    }

    /// Counts its releases, and notes the thread of the last one.
    final class Released: FileCallback {

        nonisolated(unsafe) static var onMain: [Bool] = []

        func didComplete() { }
        func didRead(_ data: [UInt8]) { }
        func didList(_ names: [String]) { }
        func didGetAttributes(kind: Int32, size: Int64, modified: Int64) { }
        func didFail(_ error: Int32) { }

        deinit {
            Self.onMain.append(Thread.isMainThread)
        }
    }

    @Test @MainActor func callbacksAreReleasedOnTheMainThread() throws {
        Released.onMain = []
        let queue = DispatchQueue(label: "test.files.release")
        try AndroidFiles.configure(AndroidFiles.Configuration(
            directories: Self.directories(root),
            assets: MemoryAssets(resources: Self.resources),
            work: { job in queue.async { job(); Thread.sleep(forTimeInterval: 0.05) } }
        ))
        let files = AndroidFiles.shared()
        for _ in 0..<5 {
            files.attributes(Self.bundle, path: "welcome.txt", callback: Released())
        }
        // Answer each one while its worker's closure is still alive.
        let deadline = Date().addingTimeInterval(5)
        while Released.onMain.count < 5, Date() < deadline {
            MainLooper.shared.drain()
            Thread.sleep(forTimeInterval: 0.01)
        }
        queue.sync { }
        #expect(Released.onMain == [true, true, true, true, true])
    }

    @Test func answersOnTheMainLooperInOrder() async throws {
        Recorder.answers = []
        let queue = DispatchQueue(label: "test.files")
        try AndroidFiles.configure(AndroidFiles.Configuration(
            directories: Self.directories(root),
            assets: MemoryAssets(resources: Self.resources),
            work: { queue.async(execute: $0) }
        ))
        let files = AndroidFiles.shared()
        files.write(Self.documents, path: "a.txt", data: Array("first".utf8), mode: 0, callback: Recorder("write"))
        files.read(Self.documents, path: "a.txt", offset: 0, length: -1, callback: Recorder("read"))
        files.copy(Self.bundle, path: "welcome.txt", toDirectory: Self.documents, toPath: "a.txt", callback: Recorder("copy"))
        files.remove(Self.documents, path: "a.txt", callback: Recorder("remove"))
        files.copy(Self.bundle, path: "welcome.txt", toDirectory: Self.documents, toPath: "a.txt", callback: Recorder("copy again"))
        files.attributes(Self.bundle, path: "welcome.txt", callback: Recorder("attributes"))
        files.list(Self.bundle, path: "levels", callback: Recorder("list"))
        files.makeDirectory(Self.bundle, path: "x", callback: Recorder("mkdir"))
        files.move(Self.documents, path: "a.txt", toDirectory: Self.documents, toPath: "b.txt", callback: Recorder("move"))
        queue.sync { }
        #expect(Recorder.answers.isEmpty, "nothing is answered off the main looper")
        MainLooper.shared.drain()
        #expect(Recorder.answers == [
            "write: complete",
            "read: first",
            "copy: error 3",
            "remove: complete",
            "copy again: complete",
            "attributes: 0 24 0",
            "list: [\"1.map\", \"boss/\"]",
            "mkdir: error 7",
            "move: complete",
        ])
        #expect(onDisk("files/Documents/b.txt") == "Welcome to the notebook.")
    }
}
