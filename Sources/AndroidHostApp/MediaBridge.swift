import AndroidHost
import AndroidHostMedia
import SwiftJava

/// The Kotlin `MediaSystem` (`:appruntime-contracts`).
@JavaClass("org.pureswift.appruntime.contracts.MediaSystem")
open class JavaMediaSystem: JavaObject {

    @JavaMethod
    @_nonoverride public convenience init(environment: JNIEnvironment? = nil)

    @JavaMethod open func make(_ id: Int32)
    @JavaMethod open func load(_ id: Int32, _ location: String)
    @JavaMethod open func loadData(_ id: Int32, _ bytes: [Int8], _ fileExtension: String)
    @JavaMethod open func unload(_ id: Int32)
    @JavaMethod open func play(_ id: Int32)
    @JavaMethod open func pause(_ id: Int32)
    @JavaMethod open func seek(_ id: Int32, _ seconds: Double, _ request: Int32)
    @JavaMethod open func position(_ id: Int32) -> Double
    @JavaMethod open func setRate(_ id: Int32, _ rate: Float)
    @JavaMethod open func setVolume(_ id: Int32, _ volume: Float)
    @JavaMethod open func setMuted(_ id: Int32, _ muted: Bool)
    @JavaMethod open func setLooping(_ id: Int32, _ looping: Bool)
    @JavaMethod open func setTimeUpdateInterval(_ id: Int32, _ milliseconds: Int64)
    @JavaMethod open func release(_ id: Int32)
    @JavaMethod open func canPlay(_ mimeType: String) -> Int32
}

extension JavaMediaSystem: MediaPlayerSystem {

    public func load(_ id: Int32, location: String) {
        load(id, location)
    }

    public func loadData(_ id: Int32, bytes: [UInt8], fileExtension: String) {
        loadData(id, bytes.map { Int8(bitPattern: $0) }, fileExtension)
    }

    public func seek(_ id: Int32, seconds: Double, request: Int32) {
        seek(id, seconds, request)
    }

    public func setTimeUpdateInterval(_ id: Int32, milliseconds: Int64) {
        setTimeUpdateInterval(id, milliseconds)
    }
}

/// The Kotlin `NowPlayingSystem` (`:appruntime-contracts`).
@JavaClass("org.pureswift.appruntime.contracts.NowPlayingSystem")
open class JavaNowPlayingSystem: JavaObject {

    @JavaMethod
    @_nonoverride public convenience init(environment: JNIEnvironment? = nil)

    @JavaMethod open func show(_ title: String, _ artist: String, _ hasArtist: Bool, _ album: String, _ hasAlbum: Bool,
                               _ commands: Int32, _ skipBackward: Double, _ skipForward: Double,
                               _ position: Double, _ duration: Double, _ rate: Float, _ playing: Bool)
    @JavaMethod open func hide()
    @JavaMethod open func artwork(_ location: String, _ bytes: [Int8])
    @JavaMethod open func setBackground(_ enabled: Bool)
}

extension JavaNowPlayingSystem: NowPlayingSystem {

    public func show(title: String, artist: String?, album: String?, commands: Int32, skipBackward: Double, skipForward: Double,
                     position: Double, duration: Double?, rate: Float, playing: Bool) {
        // Natives take no optional strings: each comes with whether it's there.
        show(title, artist ?? "", artist != nil, album ?? "", album != nil, commands, skipBackward, skipForward,
             position, duration ?? -1, rate, playing)
    }

    public func artwork(location: String, bytes: [UInt8]) {
        artwork(location, bytes.map { Int8(bitPattern: $0) })
    }
}

/// The Kotlin `NowPlayingNatives` object: the session's buttons.
@JavaClass("org.pureswift.appruntime.contracts.NowPlayingNatives")
open class NowPlayingNatives: JavaObject {}

@JavaImplementation("org.pureswift.appruntime.contracts.NowPlayingNatives")
extension NowPlayingNatives {

    @JavaMethod
    public func command(_ command: Int32, _ seconds: Double) {
        AndroidMedia.command(command, seconds: seconds)
    }
}

/// The Kotlin `MediaNatives` object: what the players do.
@JavaClass("org.pureswift.appruntime.contracts.MediaNatives")
open class MediaNatives: JavaObject {}

@JavaImplementation("org.pureswift.appruntime.contracts.MediaNatives")
extension MediaNatives {

    @JavaMethod
    public func loaded(_ id: Int32, _ duration: Double, _ width: Int32, _ height: Int32, _ hasAudio: Bool, _ hasVideo: Bool) {
        AndroidMedia.loaded(id, duration: duration, width: width, height: height, hasAudio: hasAudio, hasVideo: hasVideo)
    }

    @JavaMethod
    public func state(_ id: Int32, _ state: Int32, _ reason: Int32) {
        AndroidMedia.state(id, state, reason: reason)
    }

    @JavaMethod
    public func time(_ id: Int32, _ position: Double, _ rate: Float) {
        AndroidMedia.time(id, position: position, rate: rate)
    }

    @JavaMethod
    public func buffer(_ id: Int32, _ seconds: Double) {
        AndroidMedia.buffer(id, seconds: seconds)
    }

    @JavaMethod
    public func seeked(_ id: Int32, _ request: Int32, _ finished: Bool) {
        AndroidMedia.seeked(id, request: request, finished: finished)
    }

    @JavaMethod
    public func ended(_ id: Int32) {
        AndroidMedia.ended(id)
    }

    @JavaMethod
    public func failed(_ id: Int32, _ code: Int32, _ message: String) {
        AndroidMedia.failed(id, code: code, message: message)
    }
}
