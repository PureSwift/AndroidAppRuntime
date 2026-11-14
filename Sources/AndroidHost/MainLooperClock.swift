import RuntimeCore

/// The `Clock` built-in (§5.4) on the main looper: `CLOCK_BOOTTIME` for
/// `now`, the looper's timers for `schedule`, so timers fire on the main
/// thread.
public final class MainLooperClock: HostClock {

    public let looper: MainLooper

    public init(looper: MainLooper = .shared) {
        self.looper = looper
    }

    public func now() -> Int64 {
        MainLooper.now()
    }

    public func schedule(after nanoseconds: Int64, _ body: @escaping () -> Void) {
        looper.schedule(after: nanoseconds, body)
    }
}
