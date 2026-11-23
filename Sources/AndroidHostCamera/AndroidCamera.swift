import AndroidHost
import DynamicCamera
import DynamicRuntime
import RuntimeCore
import RuntimeCamera
import RuntimeHost

/// What a camera asks of CameraX (`Plan.md` §6.19): the Kotlin
/// `CameraSystem`, one camera per guest `Camera`, by the identifier its
/// `CameraPreview` node carries. Tests use a fake. Main thread only; what
/// the cameras do comes back through `CameraHub`.
public protocol CameraSystem: AnyObject {

    /// The device's cameras: bits, 1 back, 2 front, 4 external.
    func positions() -> Int32

    func make(_ id: Int32)

    func destroy(_ id: Int32)

    /// Answered by `CameraHub.started` or `failed`.
    func start(_ id: Int32, position: Int32)

    func stop(_ id: Int32)

    func setZoom(_ id: Int32, factor: Double)

    func setFlashMode(_ id: Int32, mode: Int32)

    /// Answered by `CameraHub.photo` with `request`.
    func capturePhoto(_ id: Int32, path: String, request: Int32)

    /// Answered by `CameraHub.recordingStarted` with `request`.
    func startRecording(_ id: Int32, path: String, audio: Bool, request: Int32)

    /// Then `CameraHub.recordingFinished`.
    func stopRecording(_ id: Int32)
}

/// A `CameraError` from Kotlin: -1 is `unknown`, since 0 is no error.
func cameraError(_ code: Int32) -> CameraError {
    CameraError(rawValue: code) ?? .unknown
}

/// One camera: CameraX use cases the Kotlin side binds while it's on.
final class AndroidCameraEngine: CameraEngine {

    private(set) weak var camera: HostCameraCapture?

    let id: Int32

    private let system: any CameraSystem

    private var nextRequest: Int32 = 1

    private var photos: [Int32: (Result<(width: Int, height: Int), CameraError>) -> Void] = [:]

    private var recordings: [Int32: (CameraError?) -> Void] = [:]

    init(camera: HostCameraCapture, system: any CameraSystem) {
        self.camera = camera
        self.id = camera.identifier()
        self.system = system
        system.make(id)
        CameraHub.shared.register(self)
    }

    deinit {
        CameraHub.shared.unregister(id)
        system.destroy(id)
    }

    private func request() -> Int32 {
        defer { nextRequest += 1 }
        return nextRequest
    }

    func start(_ position: CameraPosition) {
        system.start(id, position: position.rawValue)
    }

    func stop() {
        system.stop(id)
    }

    func setZoom(_ factor: Double) {
        system.setZoom(id, factor: factor)
    }

    func setFlashMode(_ mode: CameraFlashMode) {
        system.setFlashMode(id, mode: mode.rawValue)
    }

    func capturePhoto(to path: String, completion: @escaping (Result<(width: Int, height: Int), CameraError>) -> Void) {
        let request = request()
        photos[request] = completion
        system.capturePhoto(id, path: path, request: request)
    }

    func startRecording(to path: String, audio: Bool, completion: @escaping (CameraError?) -> Void) {
        let request = request()
        recordings[request] = completion
        system.startRecording(id, path: path, audio: audio, request: request)
    }

    func stopRecording() {
        system.stopRecording(id)
    }

    // MARK: From Kotlin

    func photo(_ request: Int32, width: Int32, height: Int32, error: Int32) {
        guard let completion = photos.removeValue(forKey: request) else { return }
        completion(error == 0 ? .success((Int(width), Int(height))) : .failure(cameraError(error)))
    }

    func recordingStarted(_ request: Int32, error: Int32) {
        recordings.removeValue(forKey: request)?(error == 0 ? nil : cameraError(error))
    }
}

/// Every camera, by identifier, and what CameraX reports: the Kotlin
/// side's `CameraNatives` call these on the main thread. Main thread only.
public final class CameraHub {

    nonisolated(unsafe) public static let shared = CameraHub()

    /// Makes the system on first use; `AndroidHostApp` sets it.
    public var makeSystem: (() -> any CameraSystem)?

    private var _system: (any CameraSystem)?

    var system: any CameraSystem {
        if let _system {
            return _system
        }
        guard let makeSystem else {
            fatalError("CameraHub.makeSystem isn't set")
        }
        let system = makeSystem()
        _system = system
        return system
    }

    private struct Entry {
        weak var engine: AndroidCameraEngine?
    }

    private var engines: [Int32: Entry] = [:]

    public init() { }

    /// Replaces the system, for tests.
    public func use(_ system: (any CameraSystem)?) {
        _system = system
        engines = [:]
    }

    func register(_ engine: AndroidCameraEngine) {
        engines[engine.id] = Entry(engine: engine)
    }

    func unregister(_ id: Int32) {
        engines[id] = nil
    }

    private func engine(_ id: Int32) -> AndroidCameraEngine? {
        engines[id]?.engine
    }

    // MARK: From the cameras

    public func started(_ id: Int32, minimumZoom: Double, maximumZoom: Double, hasFlash: Bool) {
        engine(id)?.camera?.started(minimumZoom: minimumZoom, maximumZoom: maximumZoom, hasFlash: hasFlash)
    }

    public func failed(_ id: Int32, error: Int32) {
        engine(id)?.camera?.failed(cameraError(error))
    }

    public func zoomChanged(_ id: Int32, factor: Double) {
        engine(id)?.camera?.zoomChanged(factor)
    }

    public func photo(_ id: Int32, request: Int32, width: Int32, height: Int32, error: Int32) {
        engine(id)?.photo(request, width: width, height: height, error: error)
    }

    public func recordingStarted(_ id: Int32, request: Int32, error: Int32) {
        engine(id)?.recordingStarted(request, error: error)
    }

    public func recordingFinished(_ id: Int32, duration: Double, mimeType: String, error: Int32) {
        engine(id)?.camera?.recordingFinished(duration: duration, mimeType: mimeType, error: error == 0 ? nil : cameraError(error))
    }
}

/// `HostCameraCapture`'s platform on Android: CameraX, and the `CAMERA` and
/// `RECORD_AUDIO` permissions.
public final class AndroidCameraPlatform: CameraPlatform {

    public static let camera = "android.permission.CAMERA"
    public static let recordAudio = "android.permission.RECORD_AUDIO"

    public init() { }

    public var positions: [CameraPosition] {
        let bits = CameraHub.shared.system.positions()
        return [CameraPosition.back, .front, .external].filter { bits & $0.rawValue != 0 }
    }

    public var access: CameraAccess {
        Self.access(AndroidPermissions.Requirement(permissions: [Self.camera], feature: "android.hardware.camera.any"))
    }

    public var microphoneAccess: CameraAccess {
        Self.access(AndroidPermissions.Requirement(permissions: [Self.recordAudio], feature: "android.hardware.microphone"))
    }

    static func access(_ requirement: AndroidPermissions.Requirement) -> CameraAccess {
        guard let system = AndroidPermissions.system else { return .unavailable }
        switch AndroidPermissions.status(requirement, system: system) {
        case .granted: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .unavailable: return .unavailable
        default: return .notDetermined
        }
    }

    public func requestAccess(_ completion: @escaping (CameraAccess) -> Void) {
        AndroidPermissions.request([Self.camera]) { _ in completion(self.access) }
    }

    public func requestMicrophoneAccess(_ completion: @escaping (CameraAccess) -> Void) {
        AndroidPermissions.request([Self.recordAudio]) { _ in completion(self.microphoneAccess) }
    }

    public func makeEngine(for camera: HostCameraCapture) -> any CameraEngine {
        AndroidCameraEngine(camera: camera, system: CameraHub.shared.system)
    }
}

/// The camera contract (`Plan.md` §6.19): AppRuntime's `HostCameraCapture`,
/// which finds each file through `HostFiles`, keeps one camera on and one
/// capture of each kind, refuses sound without leave, clamps the zoom, and
/// turns the camera off in the background, over CameraX. Needs `.camera`;
/// sound needs `.microphone` too.
public enum AndroidHostCamera: HostModule {

    public static var contracts: [ContractDescriptor] {
        HostCameraModule.contracts
    }

    public static func register(in registrar: some ContractRegistrar) {
        HostCameraModule.register(in: registrar)
    }

    public static func permissionProviders() -> [Capability: any PermissionProvider] {
        HostCameraModule.permissionProviders()
    }

    /// Points `HostCameraCapture` at CameraX. `allowsMicrophone`: the
    /// manifest declares `.microphone`. Main thread.
    public static func configure(_ makeSystem: @escaping () -> any CameraSystem, allowsMicrophone: Bool, clock: (any HostClock)?) {
        CameraHub.shared.makeSystem = makeSystem
        HostCameraCapture.platform = AndroidCameraPlatform()
        HostCameraCapture.allowsMicrophone = allowsMicrophone
        HostCameraCapture.clock = clock
    }

    /// The app left the front: the camera goes off, and a recording ends
    /// first. Main thread.
    public static func applicationDidEnterBackground() {
        HostCameraCapture.applicationDidEnterBackground()
    }

    /// The app is in front again: the camera that was on comes back.
    public static func applicationWillEnterForeground() {
        HostCameraCapture.applicationWillEnterForeground()
    }
}
