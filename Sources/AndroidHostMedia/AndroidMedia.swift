import AndroidHost
import AndroidHostFiles
import DynamicFiles
import DynamicMedia
import DynamicRuntime
import RuntimeCore
import RuntimeHost
import RuntimeMedia

/// What the media engines ask Android, through the Kotlin
/// `org.pureswift.appruntime.contracts.MediaSystem` (`AndroidHostApp` binds
/// it): Media3 `ExoPlayer`s, by identifier. Main thread only.
public protocol MediaPlayerSystem: AnyObject {

    func make(_ id: Int32)

    /// A path, an `asset:///` URI, a `content://` document, or a URL.
    func load(_ id: Int32, location: String)

    /// Bytes, kept in a file with `fileExtension` and loaded.
    func loadData(_ id: Int32, bytes: [UInt8], fileExtension: String)

    func unload(_ id: Int32)
    func play(_ id: Int32)
    func pause(_ id: Int32)

    /// Answered through `AndroidMedia.seeked` with `request`.
    func seek(_ id: Int32, seconds: Double, request: Int32)

    /// Seconds.
    func position(_ id: Int32) -> Double

    func setRate(_ id: Int32, _ rate: Float)
    func setVolume(_ id: Int32, _ volume: Float)
    func setMuted(_ id: Int32, _ muted: Bool)
    func setLooping(_ id: Int32, _ looping: Bool)
    func setTimeUpdateInterval(_ id: Int32, milliseconds: Int64)
    func release(_ id: Int32)

    /// 0 no, 1 maybe, 2 probably.
    func canPlay(_ mimeType: String) -> Int32
}

/// The media players on Android (`Plan.md` §6.10): AppRuntime's
/// `HostMediaPlayback` over an `ExoPlayer` per player, which the Kotlin
/// side drives and reports from. `HostMediaPlayback` finds files through
/// `AndroidMedia.findFile`: the bundle is the APK's assets, which Media3
/// reads as `asset:///` URIs. Main thread only.
public final class AndroidMediaPlatform: MediaPlatform {

    let system: any MediaPlayerSystem

    /// The engines by identifier, for what Android reports.
    var engines: [Int32: Weak] = [:]

    struct Weak {
        weak var engine: AndroidMediaEngine?
    }

    public init(system: any MediaPlayerSystem) {
        self.system = system
    }

    public func makeEngine(for player: HostMediaPlayback) -> any MediaEngine {
        let engine = AndroidMediaEngine(id: player.identifier(), system: system, player: player)
        engines[engine.id] = Weak(engine: engine)
        return engine
    }

    public func canPlay(_ mimeType: String) -> MediaSupport {
        MediaSupport(rawValue: system.canPlay(mimeType)) ?? .no
    }

    func engine(_ id: Int32) -> AndroidMediaEngine? {
        engines[id]?.engine
    }
}

/// One `ExoPlayer`, for one `HostMediaPlayback`. It reports what Android
/// says back to the player it was made for.
public final class AndroidMediaEngine: MediaEngine {

    let id: Int32

    let system: any MediaPlayerSystem

    /// The player that owns this engine: it holds the engine, not the
    /// other way round.
    weak var player: HostMediaPlayback?

    private var seekRequest: Int32 = 0

    private var seekCompletion: ((Bool) -> Void)?

    init(id: Int32, system: any MediaPlayerSystem, player: HostMediaPlayback) {
        self.id = id
        self.system = system
        self.player = player
        system.make(id)
    }

    deinit {
        system.release(id)
    }

    public func load(_ source: HostMediaSource) {
        answerSeek(false)
        switch source {
        case .url(let url):
            system.load(id, location: url)
        case .file(let path):
            system.load(id, location: path)
        case .data(let bytes, let mimeType):
            system.loadData(id, bytes: bytes, fileExtension: Self.fileExtension(mimeType))
        }
    }

    /// What Media3 knows a format by when it's read from a file.
    static func fileExtension(_ mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "audio/mpeg", "audio/mp3": "mp3"
        case "audio/wav", "audio/x-wav", "audio/wave": "wav"
        case "audio/mp4", "audio/m4a", "audio/x-m4a", "audio/aac": "m4a"
        case "video/quicktime": "mov"
        case "video/webm", "audio/webm": "webm"
        case "audio/ogg": "ogg"
        case "audio/flac": "flac"
        default: "mp4"
        }
    }

    public func unload() {
        answerSeek(false)
        system.unload(id)
    }

    public func play() {
        system.play(id)
    }

    public func pause() {
        system.pause(id)
    }

    public func seek(to position: Double, completion: @escaping (Bool) -> Void) {
        // One answer each: a seek another replaced is `false`.
        answerSeek(false)
        seekRequest &+= 1
        seekCompletion = completion
        system.seek(id, seconds: max(position, 0), request: seekRequest)
    }

    private func answerSeek(_ finished: Bool) {
        let completion = seekCompletion
        seekCompletion = nil
        completion?(finished)
    }

    public var currentTime: Double {
        system.position(id)
    }

    public func setRate(_ rate: Float) {
        system.setRate(id, rate)
    }

    public func setVolume(_ volume: Float) {
        system.setVolume(id, volume)
    }

    public func setMuted(_ muted: Bool) {
        system.setMuted(id, muted)
    }

    public func setLooping(_ looping: Bool) {
        system.setLooping(id, looping)
    }

    public func setTimeUpdateInterval(_ seconds: Double) {
        system.setTimeUpdateInterval(id, milliseconds: Int64((max(seconds, 0) * 1000).rounded()))
    }

    // MARK: From Android

    func seeked(_ request: Int32, finished: Bool) {
        guard request == seekRequest else { return }
        answerSeek(finished)
    }
}

/// The media module (`Plan.md` §6.10): AppRuntime's `HostMediaPlayback` on
/// Android's players.
public enum AndroidMedia: HostModule {

    /// The platform, once the host configures it.
    nonisolated(unsafe) public private(set) static var platform: AndroidMediaPlatform?

    /// Points `HostMediaPlayback` at Android's players. `allowsNetwork` is
    /// the manifest's `.network`; `allowsBackground` its
    /// `.audio(background: true)`. Main thread.
    public static func configure(_ platform: AndroidMediaPlatform, clock: (any HostClock)?, allowsNetwork: Bool, allowsBackground: Bool) {
        Self.platform = platform
        HostMediaPlayback.platform = platform
        HostMediaPlayback.clock = clock
        HostMediaPlayback.allowsNetwork = allowsNetwork
        HostMediaPlayback.allowsBackground = allowsBackground
        HostMediaPlayback.findFile = findFile
    }

    /// A file `Files` names, as Media3 takes it: the bundle's as an
    /// `asset:///` URI, a document the user picked (§6.8) as its content
    /// URI, and the app's own as a path. A document's is found by asking its
    /// provider, on the main thread: a folder's paths are walked by name.
    static func findFile(_ directory: Int32, _ path: String) throws(FileError) -> String {
        if directory == FileDirectory.bundle.rawValue {
            return "asset:///" + (try AndroidFiles.shared().bundleAsset(path))
        }
        if FileDirectory(rawValue: directory).isGrant {
            return try AndroidFiles.shared().contentURI(of: directory, path: path)
        }
        return try HostMediaPlayback.findPath(directory, path)
    }

    /// The app left the front: what doesn't play in the background pauses.
    public static func applicationDidEnterBackground() {
        HostMediaPlayback.applicationDidEnterBackground()
    }

    // MARK: From Android

    static func engine(_ id: Int32) -> AndroidMediaEngine? {
        platform?.engine(id)
    }

    public static func loaded(_ id: Int32, duration: Double, width: Int32, height: Int32, hasAudio: Bool, hasVideo: Bool) {
        engine(id)?.player?.loaded(duration: duration < 0 ? nil : duration, width: Int(width), height: Int(height),
                                  hasAudio: hasAudio, hasVideo: hasVideo)
    }

    public static func state(_ id: Int32, _ state: Int32, reason: Int32) {
        guard let new = MediaState(rawValue: state) else { return }
        engine(id)?.player?.stateChanged(new, reason: MediaPauseReason(rawValue: reason) ?? .requested)
    }

    public static func time(_ id: Int32, position: Double, rate: Float) {
        engine(id)?.player?.timeChanged(position: position, rate: rate)
    }

    public static func buffer(_ id: Int32, seconds: Double) {
        engine(id)?.player?.bufferChanged(seconds)
    }

    public static func seeked(_ id: Int32, request: Int32, finished: Bool) {
        engine(id)?.seeked(request, finished: finished)
    }

    public static func ended(_ id: Int32) {
        engine(id)?.player?.ended()
    }

    public static func failed(_ id: Int32, code: Int32, message: String) {
        engine(id)?.player?.failed(MediaError(MediaError.Code(rawValue: code) ?? .unknown, message: message))
    }

    // MARK: The module

    public static var contracts: [ContractDescriptor] {
        HostMediaModule.contracts
    }

    public static func register(in registrar: some ContractRegistrar) {
        HostMediaModule.register(in: registrar)
    }

    public static func permissionProviders() -> [Capability: any PermissionProvider] {
        HostMediaModule.permissionProviders()
    }
}
