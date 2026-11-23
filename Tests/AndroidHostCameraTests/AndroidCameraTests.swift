import Foundation
import Testing
import AndroidHost
import DynamicCamera
import DynamicFiles
import DynamicRuntime
import RuntimeCamera
import RuntimeHost
@testable import AndroidHostCamera

/// The Kotlin side's CameraX, in memory: the calls the engines made.
final class ScriptedCameraX: CameraSystem {

    var bits: Int32 = 3

    var calls: [String] = []

    func positions() -> Int32 { bits }
    func make(_ id: Int32) { calls.append("make") }
    func destroy(_ id: Int32) { calls.append("destroy") }
    func start(_ id: Int32, position: Int32) { calls.append("start \(position)") }
    func stop(_ id: Int32) { calls.append("stop") }
    func setZoom(_ id: Int32, factor: Double) { calls.append("zoom \(factor)") }
    func setFlashMode(_ id: Int32, mode: Int32) { calls.append("flash \(mode)") }

    var photos: [(path: String, request: Int32)] = []

    func capturePhoto(_ id: Int32, path: String, request: Int32) {
        photos.append((path, request))
    }

    var recordings: [(path: String, audio: Bool, request: Int32)] = []

    func startRecording(_ id: Int32, path: String, audio: Bool, request: Int32) {
        recordings.append((path, audio, request))
    }

    func stopRecording(_ id: Int32) { calls.append("stopRecording") }
}

final class Permissions: PermissionSystem {

    var apiLevel: Int32 = 34
    var granted: Set<String> = []
    var requested: Set<String> = []
    var requests: [(permissions: [String], id: Int32)] = []

    func isGranted(_ permission: String) -> Bool { granted.contains(permission) }
    func wasRequested(_ permission: String) -> Bool { requested.contains(permission) }
    func isDeclared(_ permission: String) -> Bool { true }
    func hasFeature(_ feature: String) -> Bool { true }

    func request(_ permissions: [String], id: Int32) -> Bool {
        requests.append((permissions, id))
        requested.formUnion(permissions)
        return true
    }
}

/// What the guest hears.
final class Booth: CameraCaptureDelegate {

    var events: [String] = []

    func didChangeAccess(_ access: Int32, microphone: Bool) { events.append("access \(access) \(microphone)") }
    func didChangeState(_ state: Int32) { events.append("state \(state)") }

    func didStart(_ position: Int32, minimumZoom: Double, maximumZoom: Double, hasFlash: Bool) {
        events.append("started \(position) \(minimumZoom)...\(maximumZoom) \(hasFlash)")
    }

    func didChangeZoom(_ factor: Double) { events.append("zoom \(factor)") }
    func didFail(_ error: Int32) { events.append("fail \(error)") }
    func didCapturePhoto(_ request: Int32, width: Int32, height: Int32) { events.append("photo \(request) \(width)x\(height)") }
    func didStartRecording(_ request: Int32, timestamp: Int64) { events.append("recording \(request)") }

    func didFinishRecording(_ request: Int32, duration: Double, mimeType: String, error: Int32) {
        events.append("finished \(request) \(duration) \(mimeType) \(error)")
    }

    func didFailCapture(_ request: Int32, error: Int32) { events.append("capture failed \(request) \(error)") }

    func take() -> [String] {
        defer { events = [] }
        return events
    }
}

/// `HostCameraCapture` over `AndroidCameraPlatform`, over a scripted
/// CameraX, with Android's permissions as access. Serialized: the camera,
/// the files and the permissions are global.
@Suite(.serialized) final class AndroidCameraTests {

    let camerax = ScriptedCameraX()

    let permissions = Permissions()

    let booth = Booth()

    let root = Foundation.FileManager.default.temporaryDirectory.appendingPathComponent("AndroidCameraTests-\(UUID().uuidString)")

    init() {
        HostCameraCapture.reset()
        AndroidPermissions.reset()
        AndroidPermissions.system = permissions
        CameraHub.shared.use(camerax)
        AndroidHostCamera.configure({ ScriptedCameraX() }, allowsMicrophone: true, clock: nil)
    }

    deinit {
        HostCameraCapture.reset()
        AndroidPermissions.reset()
        AndroidPermissions.system = nil
        CameraHub.shared.use(nil)
        try? Foundation.FileManager.default.removeItem(at: root)
    }

    /// A camera that's on, at the back, from 1 to 8.
    func running() -> HostCameraCapture {
        permissions.granted = [AndroidCameraPlatform.camera]
        let camera = HostCameraCapture.make(booth)
        camera.start(CameraPosition.back.rawValue)
        CameraHub.shared.started(camera.identifier(), minimumZoom: 1, maximumZoom: 8, hasFlash: true)
        _ = booth.take()
        camerax.calls = []
        return camera
    }

    /// `caches` in a directory of the test's own.
    func files() throws {
        try HostFiles.configure(HostFiles.Configuration(
            directories: [.caches: root.appendingPathComponent("caches").path],
            work: { $0() }, deliver: { $0() }
        ))
    }

    @Test func positionsAndAccessAreAndroids() {
        #expect(HostCameraCapture.positions() == 3)
        camerax.bits = 4
        #expect(HostCameraCapture.positions() == CameraPosition.external.rawValue)
        #expect(HostCameraCapture.access() == CameraAccess.notDetermined.rawValue)
        HostCameraCapture.requestAccess(booth)
        #expect(permissions.requests.last?.permissions == [AndroidCameraPlatform.camera])
        permissions.granted = [AndroidCameraPlatform.camera]
        AndroidPermissions.didRequest(id: permissions.requests.last?.id ?? 0, permissions: [AndroidCameraPlatform.camera], granted: [true])
        #expect(booth.take() == ["access \(CameraAccess.authorized.rawValue) false"])
        // Refused, the microphone.
        HostCameraCapture.requestMicrophoneAccess(booth)
        #expect(permissions.requests.last?.permissions == [AndroidCameraPlatform.recordAudio])
        AndroidPermissions.didRequest(id: permissions.requests.last?.id ?? 0, permissions: [AndroidCameraPlatform.recordAudio], granted: [false])
        #expect(booth.take() == ["access \(CameraAccess.denied.rawValue) true"])
    }

    @Test func startsThroughCameraX() {
        permissions.granted = [AndroidCameraPlatform.camera]
        var camera: HostCameraCapture? = HostCameraCapture.make(booth)
        let id = camera!.identifier()
        camera?.start(CameraPosition.front.rawValue)
        #expect(camerax.calls == ["make", "start 2"])
        CameraHub.shared.started(id, minimumZoom: 1, maximumZoom: 10, hasFlash: false)
        #expect(booth.take() == ["state 1", "started 2 1.0...10.0 false", "state 2"])
        // Released: off, and gone.
        camera = nil
        #expect(camerax.calls.suffix(2) == ["stop", "destroy"])
        // What it says afterwards goes nowhere.
        CameraHub.shared.failed(id, error: 3)
    }

    @Test func aCameraCameraXCantOpenFails() {
        permissions.granted = [AndroidCameraPlatform.camera]
        let camera = HostCameraCapture.make(booth)
        camera.start(CameraPosition.back.rawValue)
        CameraHub.shared.failed(camera.identifier(), error: CameraError.unavailable.rawValue)
        #expect(booth.take() == ["state 1", "state 4", "fail \(CameraError.unavailable.rawValue)"])
        // Unknown, which can't be 0 from Kotlin.
        #expect(cameraError(-1) == .unknown)
    }

    @Test func aPinchIsClampedAndToldAndZoomGoesToCameraX() {
        let camera = running()
        CameraHub.shared.zoomChanged(camera.identifier(), factor: 3)
        CameraHub.shared.zoomChanged(camera.identifier(), factor: 20)
        #expect(booth.take() == ["zoom 3.0", "zoom 8.0"])
        camera.setZoom(0.5)
        #expect(camerax.calls == ["zoom 1.0"])
        camera.setFlashMode(CameraFlashMode.auto.rawValue)
        #expect(camerax.calls.last == "flash 2")
    }

    @Test func aPhotoIsWrittenWhereFilesSays() throws {
        try files()
        let camera = running()
        camera.capturePhoto(FileDirectory.caches.rawValue, path: "shots/one.jpg", request: 7)
        let photo = try #require(camerax.photos.last)
        #expect(photo.path == root.appendingPathComponent("caches/shots/one.jpg").path)
        // A second while the first is taken is refused.
        camera.capturePhoto(FileDirectory.caches.rawValue, path: "two.jpg", request: 8)
        #expect(booth.take() == ["capture failed 8 \(CameraError.busy.rawValue)"])
        CameraHub.shared.photo(camera.identifier(), request: photo.request, width: 3000, height: 4000, error: 0)
        #expect(booth.take() == ["photo 7 3000x4000"])
        // A failure, and an answer for nothing.
        camera.capturePhoto(FileDirectory.caches.rawValue, path: "three.jpg", request: 9)
        CameraHub.shared.photo(camera.identifier(), request: camerax.photos.last?.request ?? 0, width: 0, height: 0,
                               error: CameraError.writeFailed.rawValue)
        CameraHub.shared.photo(camera.identifier(), request: 99, width: 1, height: 1, error: 0)
        #expect(booth.take() == ["capture failed 9 \(CameraError.writeFailed.rawValue)"])
    }

    @Test func aRecordingBeginsAndEndsWithItsFile() throws {
        try files()
        let camera = running()
        permissions.granted = [AndroidCameraPlatform.camera, AndroidCameraPlatform.recordAudio]
        camera.startRecording(FileDirectory.caches.rawValue, path: "clip.mp4", audio: true, request: 3)
        let recording = try #require(camerax.recordings.last)
        #expect(recording.audio)
        CameraHub.shared.recordingStarted(camera.identifier(), request: recording.request, error: 0)
        #expect(booth.take() == ["recording 3"])
        camera.stopRecording()
        #expect(camerax.calls.last == "stopRecording")
        CameraHub.shared.recordingFinished(camera.identifier(), duration: 2.5, mimeType: "video/mp4", error: 0)
        #expect(booth.take() == ["finished 3 2.5 video/mp4 0"])
        // One CameraX couldn't begin.
        camera.startRecording(FileDirectory.caches.rawValue, path: "clip2.mp4", audio: false, request: 4)
        CameraHub.shared.recordingStarted(camera.identifier(), request: camerax.recordings.last?.request ?? 0,
                                          error: CameraError.busy.rawValue)
        #expect(booth.take() == ["capture failed 4 \(CameraError.busy.rawValue)"])
    }

    @Test func soundNeedsTheUsersLeave() throws {
        try files()
        let camera = running()
        camera.startRecording(FileDirectory.caches.rawValue, path: "clip.mp4", audio: true, request: 5)
        #expect(camerax.recordings.isEmpty)
        #expect(booth.take() == ["capture failed 5 \(CameraError.notAuthorized.rawValue)"])
    }

    @Test func theBackgroundTurnsTheCameraOffAndOnAgain() throws {
        try files()
        let camera = running()
        camera.startRecording(FileDirectory.caches.rawValue, path: "clip.mp4", audio: false, request: 6)
        CameraHub.shared.recordingStarted(camera.identifier(), request: camerax.recordings.last?.request ?? 0, error: 0)
        _ = booth.take()
        AndroidHostCamera.applicationDidEnterBackground()
        #expect(camerax.calls == ["stopRecording", "stop"])
        #expect(booth.take() == ["state 3"])
        // The file is kept, cut short.
        CameraHub.shared.recordingFinished(camera.identifier(), duration: 1, mimeType: "video/mp4", error: 0)
        #expect(booth.take() == ["finished 6 1.0 video/mp4 \(CameraError.interrupted.rawValue)"])
        AndroidHostCamera.applicationWillEnterForeground()
        #expect(camerax.calls.last == "start 1")
        CameraHub.shared.started(camera.identifier(), minimumZoom: 1, maximumZoom: 8, hasFlash: true)
        #expect(booth.take().last == "state 2")
    }
}
