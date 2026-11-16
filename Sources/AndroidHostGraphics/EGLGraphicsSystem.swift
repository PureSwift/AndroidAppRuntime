#if os(Android)
import AndroidHost
import CAndroidHost

/// EGL on the main thread, through `CAndroidHost`: one GLES 2.0 context
/// for every surface, an EGL window surface per view, and frames from the
/// main thread's `AChoreographer`.
public final class EGLGraphicsSystem: GraphicsSystem {

    private struct Drawable {
        var window: UnsafeMutableRawPointer
        var drawable: UnsafeMutableRawPointer
    }

    private var drawables: [Int32: Drawable] = [:]

    private var frame: ((Int64) -> Void)?

    public init() { }

    deinit {
        for id in Array(drawables.keys) {
            detach(id)
        }
    }

    public func attach(_ surface: Int32, window: UnsafeMutableRawPointer) -> Bool {
        detach(surface)
        guard let drawable = candroid_gl_drawable_make(window) else {
            candroid_window_release(window)
            return false
        }
        drawables[surface] = Drawable(window: window, drawable: drawable)
        return true
    }

    public func detach(_ surface: Int32) {
        guard let drawable = drawables.removeValue(forKey: surface) else { return }
        candroid_gl_drawable_destroy(drawable.drawable)
        candroid_window_release(drawable.window)
    }

    private static func result(_ status: Int32) -> GraphicsResult {
        switch status {
        case Int32(CANDROID_GL_OK): .ok
        case Int32(CANDROID_GL_CONTEXT_LOST): .contextLost
        default: .failed
        }
    }

    public func begin(_ surface: Int32) -> GraphicsResult {
        guard let drawable = drawables[surface] else { return .failed }
        return Self.result(candroid_gl_begin(drawable.drawable))
    }

    public func end(_ surface: Int32) -> GraphicsResult {
        guard let drawable = drawables[surface] else { return .failed }
        return Self.result(candroid_gl_end(drawable.drawable))
    }

    public func replaceContext() -> Bool {
        candroid_gl_replace_context() != 0
    }

    public func requestFrame(_ frame: @escaping (Int64) -> Void) {
        guard self.frame == nil else {
            self.frame = frame
            return
        }
        self.frame = frame
        let posted = candroid_frame_post({ timestamp, data in
            guard let data else { return }
            let system = Unmanaged<EGLGraphicsSystem>.fromOpaque(data).takeUnretainedValue()
            let frame = system.frame
            system.frame = nil
            frame?(timestamp)
        }, Unmanaged.passUnretained(self).toOpaque())
        if posted == 0 {
            self.frame = nil
            HostLog.error("GLSurface: the main thread has no Choreographer; surfaces get no frames")
        }
    }

    public func timestamp(monotonic nanoseconds: Int64) -> Int64 {
        candroid_boottime_from_monotonic(nanoseconds)
    }
}
#endif
