import Foundation
import Testing
import DynamicFiles
import DynamicMedia
import RuntimeHost
import RuntimeMedia
@testable import AndroidHostFiles
@testable import AndroidHostMedia

/// The Kotlin side's players, scripted: what each was asked.
final class ScriptedPlayers: MediaPlayerSystem {

    var calls: [String] = []

    var positions: [Int32: Double] = [:]

    func make(_ id: Int32) { calls.append("make \(id)") }
    func load(_ id: Int32, location: String) { calls.append("load \(id) \(location)") }
    func loadData(_ id: Int32, bytes: [UInt8], fileExtension: String) { calls.append("loadData \(id) \(bytes.count) \(fileExtension)") }
    func unload(_ id: Int32) { calls.append("unload \(id)") }
    func play(_ id: Int32) { calls.append("play \(id)") }
    func pause(_ id: Int32) { calls.append("pause \(id)") }
    func seek(_ id: Int32, seconds: Double, request: Int32) { calls.append("seek \(id) \(seconds) \(request)") }
    func position(_ id: Int32) -> Double { positions[id] ?? 0 }
    func setRate(_ id: Int32, _ rate: Float) { calls.append("rate \(id) \(rate)") }
    func setVolume(_ id: Int32, _ volume: Float) { calls.append("volume \(id) \(volume)") }
    func setMuted(_ id: Int32, _ muted: Bool) { calls.append("muted \(id) \(muted)") }
    func setLooping(_ id: Int32, _ looping: Bool) { calls.append("looping \(id) \(looping)") }
    func setTimeUpdateInterval(_ id: Int32, milliseconds: Int64) { calls.append("interval \(id) \(milliseconds)") }
    func release(_ id: Int32) { calls.append("release \(id)") }

    func canPlay(_ mimeType: String) -> Int32 {
        mimeType == "audio/mpeg" ? 2 : mimeType == "video/webm" ? 1 : 0
    }
}

/// What the guest hears.
final class Heard: MediaPlaybackDelegate {

    var events: [String] = []

    func didLoad(_ duration: Double, width: Int32, height: Int32, hasAudio: Bool, hasVideo: Bool) {
        events.append("load \(duration) \(width)x\(height) audio:\(hasAudio) video:\(hasVideo)")
    }
    func didChangeState(_ state: Int32, reason: Int32) { events.append("state \(state) \(reason)") }
    func didChangeTime(_ position: Double, timestamp: Int64, rate: Float) { events.append("time \(position) \(rate)") }
    func didChangeBuffer(_ seconds: Double) { events.append("buffer \(seconds)") }
    func didSeek(_ request: Int32, finished: Bool) { events.append("seek \(request) \(finished)") }
    func didEnd() { events.append("end") }
    func didFail(_ code: Int32, message: String) { events.append("fail \(code)") }
    func didReceiveCommand(_ command: Int32) { events.append("command \(command)") }
}

/// `HostMediaPlayback` over `AndroidMediaPlatform`, with scripted players
/// and the bundle's assets in memory.
///
/// Serialized: `HostMediaPlayback` and `AndroidFiles` are shared.
@Suite(.serialized) final class AndroidMediaTests {

    let players = ScriptedPlayers()

    init() throws {
        HostMediaPlayback.reset()
        AndroidMedia.configure(AndroidMediaPlatform(system: players), clock: nil, allowsNetwork: true, allowsBackground: false)
        try AndroidFiles.configure(AndroidFiles.Configuration(
            directories: [:],
            assets: MemoryAssets(["rt/resources/music/morning.mp3": [1, 2, 3], "rt/resources.index": Array("music/morning.mp3\n".utf8)]),
            content: OneFolder()
        ))
    }

    deinit {
        HostMediaPlayback.reset()
    }

    @Test func eachPlayerIsAnExoPlayerByItsIdentifier() {
        var player: HostMediaPlayback? = HostMediaPlayback.make(Heard())
        let id = player!.identifier()
        #expect(players.calls == ["make \(id)"])
        player = nil
        #expect(players.calls.last == "release \(id)")
    }

    @Test func theBundleIsTheAPKsAssets() {
        let heard = Heard()
        let player = HostMediaPlayback.make(heard)
        let id = player.identifier()
        player.loadFile(FileDirectory.bundle.rawValue, path: "music/morning.mp3")
        #expect(players.calls.last == "load \(id) asset:///rt/resources/music/morning.mp3")
        player.loadFile(FileDirectory.bundle.rawValue, path: "music/none.mp3")
        player.loadFile(FileDirectory.bundle.rawValue, path: "music")
        #expect(heard.events.suffix(2) == ["state 5 0", "fail 1"])
        #expect(players.calls.filter { $0.hasPrefix("load ") }.count == 1, "neither reached the player")
        player.loadURL("https://example.com/a.mp3")
        #expect(players.calls.last == "load \(id) https://example.com/a.mp3")
        player.loadData([1, 2], mimeType: "audio/mpeg")
        #expect(players.calls.last == "loadData \(id) 2 mp3")
    }

    @Test func aPickedDocumentIsItsContentURI() {
        let heard = Heard()
        let player = HostMediaPlayback.make(heard)
        let id = player.identifier()
        let folder = DocumentGrants.grant(ContentGrant(uri: "content://music/root", kind: .directory, isWritable: false))
        defer { DocumentGrants.revoke(folder) }
        player.loadFile(folder.rawValue, path: "song.mp3")
        #expect(players.calls.last == "load \(id) content://music/song")
        player.loadFile(folder.rawValue, path: "none.mp3")
        #expect(heard.events.last == "fail 1")
        DocumentGrants.revoke(folder)
        player.loadFile(folder.rawValue, path: "song.mp3")
        #expect(heard.events.last == "fail 4", "a document the app no longer holds")
    }

    @Test func whatAndroidSaysReachesTheGuest() {
        let heard = Heard()
        let player = HostMediaPlayback.make(heard)
        let id = player.identifier()
        player.loadURL("https://example.com/a.mp3")
        player.play()
        AndroidMedia.loaded(id, duration: 180, width: 0, height: 0, hasAudio: true, hasVideo: false)
        // A play that came too early starts it.
        #expect(players.calls.last == "play \(id)")
        AndroidMedia.state(id, 3, reason: 0)
        AndroidMedia.time(id, position: 1.5, rate: 1)
        AndroidMedia.buffer(id, seconds: 20)
        // Unplugged headphones.
        AndroidMedia.state(id, 2, reason: 6)
        AndroidMedia.ended(id)
        AndroidMedia.failed(id, code: 3, message: "lost")
        #expect(heard.events == [
            "state 1 0", "load 180.0 0x0 audio:true video:false", "state 2 0", "state 3 0", "time 1.5 1.0",
            "buffer 20.0", "state 2 6", "state 2 4", "end", "state 5 0", "fail 3",
        ])
        // A live stream has no duration.
        player.loadURL("https://example.com/live.m3u8")
        AndroidMedia.loaded(id, duration: -1, width: 1280, height: 720, hasAudio: true, hasVideo: true)
        #expect(heard.events.contains("load -1.0 1280x720 audio:true video:true"))
    }

    @Test func eachSeekIsAnsweredOnce() {
        let heard = Heard()
        let player = HostMediaPlayback.make(heard)
        let id = player.identifier()
        player.loadURL("https://example.com/a.mp3")
        AndroidMedia.loaded(id, duration: 180, width: 0, height: 0, hasAudio: true, hasVideo: false)
        player.seek(30, request: 7)
        player.seek(60, request: 8)
        #expect(players.calls.suffix(2) == ["seek \(id) 30.0 1", "seek \(id) 60.0 2"])
        // Android's answer to the first comes after the second was asked.
        AndroidMedia.seeked(id, request: 1, finished: true)
        AndroidMedia.seeked(id, request: 2, finished: true)
        #expect(heard.events.filter { $0.hasPrefix("seek") } == ["seek 7 false", "seek 8 true"])
    }

    @Test func settingsGoToThePlayer() {
        let player = HostMediaPlayback.make(Heard())
        let id = player.identifier()
        player.setRate(1.5)
        player.setVolume(0.25)
        player.setMuted(true)
        player.setLooping(true)
        player.setTimeUpdateInterval(0.5)
        #expect(players.calls.suffix(5) == ["rate \(id) 1.5", "volume \(id) 0.25", "muted \(id) true", "looping \(id) true", "interval \(id) 500"])
        #expect(HostMediaPlayback.canPlay("audio/mpeg") == 2)
        #expect(HostMediaPlayback.canPlay("video/webm") == 1)
        #expect(HostMediaPlayback.canPlay("audio/ogg") == 0)
    }

    @Test func leavingTheFrontPausesWhatDoesntPlayOn() {
        let heard = Heard()
        let player = HostMediaPlayback.make(heard)
        let id = player.identifier()
        player.loadURL("https://example.com/a.mp3")
        AndroidMedia.loaded(id, duration: 180, width: 0, height: 0, hasAudio: true, hasVideo: false)
        player.play()
        AndroidMedia.state(id, 3, reason: 0)
        AndroidMedia.applicationDidEnterBackground()
        #expect(players.calls.last == "pause \(id)")
        // Android says it paused at the guest's request; the reason is the
        // background's.
        AndroidMedia.state(id, 2, reason: 0)
        #expect(heard.events.last == "state 2 3")
    }
}

/// The APK's assets, in memory.
struct MemoryAssets: AssetReader {

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

/// A picked folder with one song in it.
final class OneFolder: ContentStore {

    func info(_ uri: String) throws(FileError) -> ContentInfo {
        ContentInfo(name: uri, kind: uri.hasSuffix("root") ? .directory : .file)
    }

    func children(_ uri: String) throws(FileError) -> [ContentChild] {
        uri == "content://music/root" ? [ContentChild(uri: "content://music/song", name: "song.mp3", kind: .file)] : []
    }

    func read(_ uri: String, offset: Int64, length: Int64) throws(FileError) -> [UInt8] { [] }
    func write(_ uri: String, data: [UInt8], append: Bool) throws(FileError) { throw .readOnly }
    func create(in parent: String, name: String, kind: FileKind) throws(FileError) -> String { throw .readOnly }
    func delete(_ uri: String) throws(FileError) { throw .readOnly }
}
