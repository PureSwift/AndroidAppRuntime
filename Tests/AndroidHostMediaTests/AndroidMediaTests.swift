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
/// The Kotlin side's session, scripted: what it was told to show.
final class ScriptedSession: NowPlayingSystem {

    var calls: [String] = []

    func show(title: String, artist: String?, album: String?, commands: Int32, skipBackward: Double, skipForward: Double,
              position: Double, duration: Double?, rate: Float, playing: Bool) {
        calls.append("show \(title), \(artist ?? "-"), \(album ?? "-") commands:\(commands) skip:\(skipBackward)/\(skipForward) "
                     + "at \(position) of \(duration.map { "\($0)" } ?? "live") rate:\(rate) playing:\(playing)")
    }

    func hide() { calls.append("hide") }

    func artwork(location: String, bytes: [UInt8]) {
        calls.append(location.isEmpty && bytes.isEmpty ? "no artwork" : "artwork \(location.isEmpty ? "\(bytes.count) bytes" : location)")
    }

    func setBackground(_ enabled: Bool) { calls.append("background \(enabled)") }
}

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

    let session = ScriptedSession()

    init() throws {
        HostMediaPlayback.reset()
        AndroidMedia.configure(AndroidMediaPlatform(system: players, nowPlaying: session), clock: nil,
                               allowsNetwork: true, allowsBackground: false)
        try AndroidFiles.configure(AndroidFiles.Configuration(
            directories: [:],
            assets: MemoryAssets(["rt/resources/music/morning.mp3": [1, 2, 3], "rt/resources/music/cover.png": [4],
                                 "rt/resources.index": Array("music/morning.mp3\nmusic/cover.png\n".utf8)]),
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

    // MARK: Now playing

    /// A player playing the bundle's song, described.
    func describedPlayer(_ heard: Heard) -> HostMediaPlayback {
        let player = HostMediaPlayback.make(heard)
        player.loadFile(FileDirectory.bundle.rawValue, path: "music/morning.mp3")
        AndroidMedia.loaded(player.identifier(), duration: 8, width: 0, height: 0, hasAudio: true, hasVideo: false)
        player.setNowPlaying("Morning", artist: "The Examples", album: nil)
        return player
    }

    @Test func whatsPlayingIsTheSessions() {
        let player = describedPlayer(Heard())
        let id = player.identifier()
        #expect(session.calls == [
            "background false", "no artwork",
            "show Morning, The Examples, - commands:0 skip:0.0/0.0 at 0.0 of 8.0 rate:0.0 playing:false",
        ])
        // The cover, from the APK's assets, is read once.
        player.setArtworkFile(FileDirectory.bundle.rawValue, path: "music/cover.png")
        #expect(session.calls.suffix(2).first == "artwork asset:///rt/resources/music/cover.png")
        player.setRemoteCommands(MediaRemoteCommands([.next, .previous, .skip]).rawValue, skipBackward: 10, skipForward: 30)
        player.setRate(1)
        players.positions[id] = 2
        AndroidMedia.state(id, 3, reason: 0)
        #expect(session.calls.last == "show Morning, The Examples, - commands:7 skip:10.0/30.0 at 2.0 of 8.0 rate:1.0 playing:true")
        #expect(session.calls.filter { $0.hasPrefix("artwork") }.count == 1)
        // Nothing playing, nothing shown; and once more for another song.
        player.setNowPlaying("", artist: nil, album: nil)
        #expect(session.calls.last == "hide")
        player.setNowPlaying("Noon", artist: nil, album: "Examples")
        #expect(session.calls.suffix(2) == ["no artwork", "show Noon, -, Examples commands:7 skip:10.0/30.0 at 2.0 of 8.0 rate:1.0 playing:true"])
    }

    @Test func theSessionsButtonsAreTheHostsOrTheGuests() {
        let heard = Heard()
        let player = describedPlayer(heard)
        let id = player.identifier()
        AndroidMedia.command(0, seconds: 0)
        #expect(players.calls.last == "play \(id)")
        AndroidMedia.state(id, 3, reason: 0)
        AndroidMedia.command(1, seconds: 0)
        #expect(players.calls.last == "pause \(id)")
        // The pause was the user's.
        AndroidMedia.state(id, 2, reason: 0)
        #expect(heard.events.last == "state 2 1")
        AndroidMedia.command(6, seconds: 5)
        #expect(players.calls.last?.hasPrefix("seek \(id) 5.0") == true)
        // Next, previous and skipping only where the guest offered them.
        AndroidMedia.command(2, seconds: 0)
        AndroidMedia.command(4, seconds: 0)
        #expect(!heard.events.contains("command 1"))
        player.setRemoteCommands(MediaRemoteCommands([.next, .previous, .skip]).rawValue, skipBackward: 10, skipForward: 30)
        AndroidMedia.command(2, seconds: 0)
        AndroidMedia.command(3, seconds: 0)
        #expect(heard.events.suffix(2) == ["command 1", "command 2"])
        // By the intervals the guest gave, within the song.
        players.positions[id] = 6
        AndroidMedia.command(4, seconds: 0)
        #expect(players.calls.last?.hasPrefix("seek \(id) 0.0") == true)
        players.positions[id] = 2
        AndroidMedia.command(5, seconds: 0)
        #expect(players.calls.last?.hasPrefix("seek \(id) 8.0") == true)
        AndroidMedia.command(99, seconds: 0)
    }

    @Test func withTheManifestsLeaveItPlaysOn() {
        HostMediaPlayback.reset()
        AndroidMedia.configure(AndroidMediaPlatform(system: players, nowPlaying: session), clock: nil,
                               allowsNetwork: false, allowsBackground: true)
        #expect(session.calls.last == "background true")
        #expect(HostMediaPlayback.canPlayInBackground())
        let player = describedPlayer(Heard())
        let id = player.identifier()
        player.setPlaysInBackground(true)
        player.play()
        AndroidMedia.state(id, 3, reason: 0)
        AndroidMedia.applicationDidEnterBackground()
        #expect(players.calls.last == "play \(id)")
        #expect(HostMediaPlayback.holdsApp)
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
