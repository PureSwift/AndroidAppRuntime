import AndroidHost
import AndroidHostGraphics
import CAndroidHost
import SwiftJava

/// EGL for `AndroidHostGraphics`.
enum GraphicsBridge {

    static func makeSystem() -> any GraphicsSystem {
        #if os(Android)
        return EGLGraphicsSystem()
        #else
        fatalError("surfaces draw only on Android")
        #endif
    }
}

/// The Kotlin `GraphicsSystem` (`:appruntime-contracts`): pointer capture
/// on the views.
@JavaClass("org.pureswift.appruntime.contracts.GraphicsSystem")
open class JavaGraphicsSystem: JavaObject {

    @JavaMethod
    @_nonoverride public convenience init(environment: JNIEnvironment? = nil)

    @JavaMethod open func setPointerCaptured(_ surface: Int32, _ captured: Bool) -> Bool
}

extension JavaGraphicsSystem: SurfaceViews {

    public func setPointerCaptured(_ surface: Int32, captured: Bool) -> Bool {
        setPointerCaptured(surface, captured)
    }
}

/// What the `GraphicsView`s report, on the main thread.
@JavaClass("org.pureswift.appruntime.contracts.GraphicsNatives")
open class GraphicsNatives: JavaObject {}

@JavaImplementation("org.pureswift.appruntime.contracts.GraphicsNatives")
extension GraphicsNatives {

    /// A view showing `surface` has an `android.view.Surface` to draw in.
    @JavaMethod
    public func attach(_ surface: Int32, _ window: JavaObject?, _ width: Int32, _ height: Int32, _ scale: Float) {
        #if os(Android)
        guard let window,
              let native = candroid_window_from_surface(UnsafeMutableRawPointer(window.javaEnvironment),
                                                        UnsafeMutableRawPointer(window.javaThis)) else {
            HostLog.error("GLSurface \(surface): its view has no native window")
            return
        }
        SurfaceHub.shared.attach(surface, window: native, width: width, height: height, scale: scale)
        #endif
    }

    @JavaMethod
    public func resize(_ surface: Int32, _ width: Int32, _ height: Int32, _ scale: Float) {
        SurfaceHub.shared.resize(surface, width: width, height: height, scale: scale)
    }

    @JavaMethod
    public func detach(_ surface: Int32) {
        SurfaceHub.shared.detach(surface)
    }

    @JavaMethod
    public func visible(_ surface: Int32, _ visible: Bool) {
        SurfaceHub.shared.setVisible(surface, visible: visible)
    }

    @JavaMethod
    public func pointer(_ surface: Int32, _ action: Int32, _ isActionPointer: Bool, _ pointer: Int32, _ toolType: Int32,
                        _ x: Float, _ y: Float, _ buttonState: Int32, _ eventTime: Int64) {
        SurfaceHub.shared.pointer(surface, action: action, isActionPointer: isActionPointer, pointerID: pointer,
                                  toolType: toolType, x: x, y: y, buttonState: buttonState, eventTime: eventTime)
    }

    @JavaMethod
    public func scroll(_ surface: Int32, _ horizontal: Float, _ vertical: Float, _ horizontalFactor: Float, _ verticalFactor: Float) {
        SurfaceHub.shared.scroll(surface, horizontal: horizontal, vertical: vertical,
                                 horizontalFactor: horizontalFactor, verticalFactor: verticalFactor)
    }

    @JavaMethod
    public func key(_ surface: Int32, _ action: Int32, _ keyCode: Int32, _ scanCode: Int32, _ metaState: Int32,
                    _ repeatCount: Int32, _ eventTime: Int64) -> Bool {
        SurfaceHub.shared.key(surface, action: action, keyCode: keyCode, scanCode: scanCode, metaState: metaState,
                              repeatCount: repeatCount, eventTime: eventTime)
    }

    @JavaMethod
    public func focus(_ surface: Int32, _ focused: Bool) {
        SurfaceHub.shared.focus(surface, focused: focused)
    }

    @JavaMethod
    public func capture(_ surface: Int32, _ captured: Bool) {
        SurfaceHub.shared.captureChanged(surface, captured: captured)
    }

    @JavaMethod
    public func relative(_ surface: Int32, _ x: Float, _ y: Float, _ eventTime: Int64) {
        SurfaceHub.shared.relative(surface, x: x, y: y, eventTime: eventTime)
    }
}
