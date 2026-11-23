import AndroidHost
import AndroidHostCamera
import SwiftJava

/// The Kotlin `CameraSystem` (`:appruntime-contracts`): CameraX.
@JavaClass("org.pureswift.appruntime.contracts.CameraSystem")
open class JavaCameraSystem: JavaObject {

    @JavaMethod
    @_nonoverride public convenience init(environment: JNIEnvironment? = nil)

    @JavaMethod open func positions() -> Int32
    @JavaMethod open func make(_ id: Int32)
    @JavaMethod open func destroy(_ id: Int32)
    @JavaMethod open func start(_ id: Int32, _ position: Int32)
    @JavaMethod open func stop(_ id: Int32)
    @JavaMethod open func setZoom(_ id: Int32, _ factor: Double)
    @JavaMethod open func setFlashMode(_ id: Int32, _ mode: Int32)
    @JavaMethod open func capturePhoto(_ id: Int32, _ path: String, _ request: Int32)
    @JavaMethod open func startRecording(_ id: Int32, _ path: String, _ audio: Bool, _ request: Int32)
    @JavaMethod open func stopRecording(_ id: Int32)
}

extension JavaCameraSystem: CameraSystem {

    public func start(_ id: Int32, position: Int32) { start(id, position) }
    public func setZoom(_ id: Int32, factor: Double) { setZoom(id, factor) }
    public func setFlashMode(_ id: Int32, mode: Int32) { setFlashMode(id, mode) }
    public func capturePhoto(_ id: Int32, path: String, request: Int32) { capturePhoto(id, path, request) }
    public func startRecording(_ id: Int32, path: String, audio: Bool, request: Int32) { startRecording(id, path, audio, request) }
}

/// What the cameras report, on the main thread.
@JavaClass("org.pureswift.appruntime.contracts.CameraNatives")
open class CameraNatives: JavaObject {}

@JavaImplementation("org.pureswift.appruntime.contracts.CameraNatives")
extension CameraNatives {

    @JavaMethod
    public func started(_ id: Int32, _ minimumZoom: Double, _ maximumZoom: Double, _ hasFlash: Bool) {
        CameraHub.shared.started(id, minimumZoom: minimumZoom, maximumZoom: maximumZoom, hasFlash: hasFlash)
    }

    @JavaMethod
    public func failed(_ id: Int32, _ error: Int32) {
        CameraHub.shared.failed(id, error: error)
    }

    @JavaMethod
    public func zoomChanged(_ id: Int32, _ factor: Double) {
        CameraHub.shared.zoomChanged(id, factor: factor)
    }

    @JavaMethod
    public func photo(_ id: Int32, _ request: Int32, _ width: Int32, _ height: Int32, _ error: Int32) {
        CameraHub.shared.photo(id, request: request, width: width, height: height, error: error)
    }

    @JavaMethod
    public func recordingStarted(_ id: Int32, _ request: Int32, _ error: Int32) {
        CameraHub.shared.recordingStarted(id, request: request, error: error)
    }

    @JavaMethod
    public func recordingFinished(_ id: Int32, _ duration: Double, _ mimeType: String, _ error: Int32) {
        CameraHub.shared.recordingFinished(id, duration: duration, mimeType: mimeType, error: error)
    }
}
