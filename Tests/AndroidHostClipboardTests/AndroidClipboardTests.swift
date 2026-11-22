import Foundation
import Testing
import DynamicClipboard
import DynamicFiles
import RuntimeClipboard
import RuntimeHost
@testable import AndroidHostClipboard
@testable import AndroidHostFiles

/// Android's clipboard, scripted: one clip, as `ClipboardManager` keeps it.
final class ScriptedClipboard: ClipboardSystem {

    var text: String?
    var url: String?
    var image: [UInt8] = []
    var type = ""
    var sensitive = false
    var error: Int32 = 0
    var writeResult: Int32 = 0

    func available() -> Int32 {
        (text != nil || url != nil ? 1 : 0) | (url != nil ? 2 : 0) | (image.isEmpty ? 0 : 4)
    }

    func clear() {
        text = nil
        url = nil
        image = []
    }

    func writeText(_ text: String, url: String, sensitive: Bool) {
        clear()
        self.text = text
        self.url = url.isEmpty ? nil : url
        self.sensitive = sensitive
    }

    func writeImage(_ bytes: [UInt8], fileExtension: String, sensitive: Bool) -> Int32 {
        guard writeResult == 0 else { return writeResult }
        clear()
        image = bytes
        type = fileExtension == "png" ? "image/png" : "image/jpeg"
        self.sensitive = sensitive
        return 0
    }

    func readError() -> Int32 { error }
    func readText() -> [String] { (text ?? url).map { [$0] } ?? [] }
    func readURL() -> [String] { url.map { [$0] } ?? [] }
    func readImage() -> [UInt8] { image }
    func imageType() -> String { type }
}

/// What a callback heard.
final class Heard: ClipboardCallback {

    var events: [String] = []

    func didComplete() { events.append("complete") }
    func didReadText(_ text: String?) { events.append("text \(text ?? "nil")") }
    func didReadImage(_ data: [UInt8], mimeType: String) { events.append("image \(data.count) \(mimeType)") }
    func didWriteImageFile(_ mimeType: String) { events.append("file \(mimeType)") }
    func didFail(_ error: Int32) { events.append("fail \(error)") }
}

/// `HostClipboard` over `AndroidClipboardPlatform`, answering at once, and
/// snapshots over `AndroidWholeFiles`, with the bundle's assets in memory.
///
/// Serialized: `HostClipboard`, `HostFiles` and `AndroidFiles` are shared.
@Suite(.serialized) final class AndroidClipboardTests {

    let clipboard = ScriptedClipboard()

    let root: URL

    static let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0]

    init() throws {
        root = Foundation.FileManager.default.temporaryDirectory.appendingPathComponent("ClipboardTests-\(UUID().uuidString)")
        HostClipboard.reset()
        AndroidHostClipboard.configure(AndroidClipboardPlatform(system: clipboard))
        HostClipboard.deliver = { $0() }
        HostClipboard.work = { $0() }
        try AndroidFiles.configure(AndroidFiles.Configuration(
            directories: AndroidFiles.Configuration.directories(files: root.appendingPathComponent("files").path,
                                                                cache: root.appendingPathComponent("cache").path),
            assets: Assets(["rt/resources/photo.png": Self.png, "rt/resources.index": Array("photo.png\n".utf8)])
        ))
        HostFiles.wholeFiles = AndroidWholeFiles()
    }

    deinit {
        HostFiles.wholeFiles = nil
        HostClipboard.reset()
        try? Foundation.FileManager.default.removeItem(at: root)
    }

    var shared: HostClipboard { HostClipboard.shared() }

    @Test func textAndAURL() {
        let heard = Heard()
        shared.writeText("swift.org", url: "https://swift.org", options: 1, callback: heard)
        #expect(clipboard.text == "swift.org" && clipboard.url == "https://swift.org" && clipboard.sensitive)
        #expect(shared.available() == 3)
        shared.readText(heard)
        shared.readURL(heard)
        // A URL alone is text too.
        clipboard.text = nil
        shared.readText(heard)
        shared.clear(heard)
        shared.readText(heard)
        shared.readURL(heard)
        #expect(heard.events == ["complete", "text swift.org", "text https://swift.org", "text https://swift.org",
                                 "complete", "text nil", "text nil"])
    }

    @Test func images() {
        let heard = Heard()
        shared.writeImage(Self.png, mimeType: "image/jpeg", options: 0, callback: heard)
        // Told by its bytes, not the type it was given.
        #expect(clipboard.type == "image/png")
        shared.readImage(heard)
        shared.writeImage([1, 2, 3], mimeType: "image/png", options: 0, callback: heard)
        clipboard.writeResult = 0
        #expect(heard.events == ["complete", "image 10 image/png", "fail 4"])
    }

    @Test func aRefusedReadIsNotAllowed() {
        let heard = Heard()
        clipboard.text = "secret"
        clipboard.error = 2
        shared.readText(heard)
        #expect(heard.events == ["fail 2"])
    }

    /// The Kotlin side sends `unknown` as -1, since 0 is no error.
    @Test func anUnknownErrorIsMinusOne() {
        let heard = Heard()
        clipboard.writeResult = -1
        shared.writeImage(Self.png, mimeType: "image/png", options: 0, callback: heard)
        clipboard.text = "swift.org"
        clipboard.error = -1
        shared.readText(heard)
        #expect(heard.events == ["fail \(PasteboardError.unknown.rawValue)", "fail \(PasteboardError.unknown.rawValue)"])
    }

    @Test func imageFilesAreTheBundlesAndTheAppsOwn() {
        let heard = Heard()
        // The bundle is the APK's assets, which HostFiles alone can't read.
        shared.writeImageFile(FileDirectory.bundle.rawValue, path: "photo.png", options: 0, callback: heard)
        #expect(clipboard.image == Self.png)
        shared.readImageToFile(FileDirectory.documents.rawValue, path: "pasted/photo.png", callback: heard)
        #expect((try? Data(contentsOf: root.appendingPathComponent("files/Documents/pasted/photo.png"))) == Data(Self.png))
        shared.writeImageFile(FileDirectory.bundle.rawValue, path: "none.png", options: 0, callback: heard)
        shared.readImageToFile(FileDirectory.bundle.rawValue, path: "photo.png", callback: heard)
        #expect(heard.events == ["complete", "file image/png", "fail 4", "fail 2"])
    }
}

/// The APK's assets, in memory.
struct Assets: AssetReader {

    let files: [String: [UInt8]]

    init(_ files: [String: [UInt8]]) {
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
