/// EGL and the display's frames for surfaces (`Plan.md` §6.3): one GL
/// context for every surface, a drawable per window, and frames from the
/// Choreographer. `EGLGraphicsSystem` is the real one; tests use a fake.
/// Main thread only.
public protocol GraphicsSystem: AnyObject {

    /// Gives `surface` a drawable on `window`, an `ANativeWindow` the system
    /// now owns, making the context first if there's none. False if EGL
    /// refused; the window is released either way when it's done with.
    func attach(_ surface: Int32, window: UnsafeMutableRawPointer) -> Bool

    /// Destroys `surface`'s drawable and releases its window.
    func detach(_ surface: Int32)

    /// Makes the context current on `surface`'s drawable.
    func begin(_ surface: Int32) -> GraphicsResult

    /// Presents `surface`'s drawable and clears the current context.
    func end(_ surface: Int32) -> GraphicsResult

    /// Replaces a lost context with a new, empty one; false if it couldn't.
    func replaceContext() -> Bool

    /// Calls `frame` once at the next display refresh, with its time in
    /// `CLOCK_BOOTTIME` nanoseconds. Asking again before then changes
    /// nothing.
    func requestFrame(_ frame: @escaping (Int64) -> Void)

    /// An input event's `CLOCK_MONOTONIC` time on `CLOCK_BOOTTIME`, the
    /// `Clock` built-in's timeline.
    func timestamp(monotonic nanoseconds: Int64) -> Int64
}

/// How a GL step went.
public enum GraphicsResult: Equatable, Sendable {
    case ok
    case failed
    /// The context is gone, with every GL object in it.
    case contextLost
}

/// The Kotlin views' side of a surface: pointer capture (§8.6), which only
/// a view with window focus can ask for.
public protocol SurfaceViews: AnyObject {

    /// Asks the view showing `surface` to capture the mouse, or to stop;
    /// whether capture is on, or being turned on, afterwards.
    func setPointerCaptured(_ surface: Int32, captured: Bool) -> Bool
}
