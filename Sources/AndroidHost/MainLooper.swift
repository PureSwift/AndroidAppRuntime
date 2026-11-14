import CAndroidHost
#if canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The host's main loop (`Plan.md` §3.1), on Android's main thread.
///
/// Everything that calls the guest runs here (§6.4). Two file descriptors
/// are registered with the main thread's `ALooper`, so their callbacks run
/// between the Java main looper's messages:
///
/// - an `eventfd` that other threads write to after `post`ing a job;
/// - a `timerfd` on `CLOCK_BOOTTIME`, armed for the soonest timer.
///
/// The host doesn't use `DispatchQueue.main` or the main actor: JNI from a
/// native dispatch drain loses the app's class loader. Looper callbacks run
/// on the Java main thread, and swift-java finds app classes through the
/// loader it cached in `JNI_OnLoad`.
///
/// Elsewhere (macOS tests) it has no file descriptors: `drain()` runs what's
/// due.
public final class MainLooper {

    nonisolated(unsafe) public static let shared = MainLooper()

    private var timers = TimerQueue()

    private let lock = Lock()

    private var posted: [() -> Void] = []

    private var installed = false

    #if os(Android)
    private var eventFD: Int32 = -1

    private var timerFD: Int32 = -1

    /// The deadline the `timerfd` is armed for.
    private var armedDeadline: Int64?
    #endif

    public init() { }

    // MARK: Time

    /// Monotonic nanoseconds that keep counting through deep sleep
    /// (`CLOCK_BOOTTIME`), like Darwin's `mach_continuous_time`.
    public static func now() -> Int64 {
        var time = timespec()
        #if os(Android) || os(Linux)
        clock_gettime(CLOCK_BOOTTIME, &time)
        #else
        clock_gettime(CLOCK_MONOTONIC, &time)
        #endif
        return Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec)
    }

    // MARK: Installing

    /// Registers the looper's file descriptors with the calling thread's
    /// `ALooper`. Call it once, on the main thread, from `JNI_OnLoad` or the
    /// first native call. Returns whether it worked.
    @discardableResult
    public func install() -> Bool {
        guard !installed else { return true }
        #if os(Android)
        guard let looper = ALooper_forThread() else {
            HostLog.error("MainLooper.install: the calling thread has no looper")
            return false
        }
        eventFD = eventfd(0, Int32(EFD_NONBLOCK | EFD_CLOEXEC))
        timerFD = timerfd_create(CLOCK_BOOTTIME, Int32(TFD_NONBLOCK | TFD_CLOEXEC))
        guard eventFD >= 0, timerFD >= 0 else {
            HostLog.error("MainLooper.install: eventfd or timerfd failed: errno \(errno)")
            return false
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let events = Int32(ALOOPER_EVENT_INPUT)
        guard ALooper_addFd(looper, eventFD, Int32(ALOOPER_POLL_CALLBACK), events, mainLooperCallback, context) == 1,
              ALooper_addFd(looper, timerFD, Int32(ALOOPER_POLL_CALLBACK), events, mainLooperCallback, context) == 1 else {
            HostLog.error("MainLooper.install: ALooper_addFd failed")
            return false
        }
        #endif
        installed = true
        rearm()
        return true
    }

    // MARK: Jobs

    /// Runs `job` on the main thread, soon. Any thread.
    public func post(_ job: @escaping () -> Void) {
        lock.withLock {
            posted.append(job)
        }
        #if os(Android)
        if eventFD >= 0 {
            var one: UInt64 = 1
            _ = write(eventFD, &one, 8)
        }
        #endif
    }

    // MARK: Timers

    /// Runs `body` once on the main thread, at least `nanoseconds` from now.
    /// Main thread only.
    @discardableResult
    public func schedule(after nanoseconds: Int64, _ body: @escaping () -> Void) -> TimerQueue.Token {
        schedule(at: TimerQueue.deadline(after: nanoseconds, from: Self.now()), body)
    }

    /// Runs `body` once on the main thread, at or after `deadline` (`now()`'s
    /// time base). Main thread only.
    @discardableResult
    public func schedule(at deadline: Int64, _ body: @escaping () -> Void) -> TimerQueue.Token {
        let token = timers.schedule(at: deadline, body)
        rearm()
        return token
    }

    /// Cancels a timer that hasn't fired. Main thread only.
    public func cancel(_ token: TimerQueue.Token) {
        timers.cancel(token)
        rearm()
    }

    /// Timers that haven't fired.
    public var pendingTimers: Int {
        timers.count
    }

    // MARK: Running

    /// Runs posted jobs and due timers until none are left. The looper does
    /// this itself on Android; tests call it.
    public func drain() {
        repeat {
            runPosted()
            runDueTimers()
        } while hasWork
        rearm()
    }

    private var hasWork: Bool {
        let hasPosted = lock.withLock { !posted.isEmpty }
        return hasPosted || (timers.nextDeadline.map { $0 <= Self.now() } ?? false)
    }

    private func runPosted() {
        let jobs = lock.withLock {
            let jobs = posted
            posted = []
            return jobs
        }
        for job in jobs {
            job()
        }
    }

    private func runDueTimers() {
        for body in timers.takeDue(by: Self.now()) {
            body()
        }
    }

    // MARK: File descriptors

    #if os(Android)
    fileprivate func handle(_ fd: Int32) {
        var value: UInt64 = 0
        if fd == eventFD {
            _ = read(eventFD, &value, 8)
            runPosted()
        } else if fd == timerFD {
            _ = read(timerFD, &value, 8)
            armedDeadline = nil
            runDueTimers()
        }
        rearm()
    }
    #endif

    /// Arms the `timerfd` for the soonest timer, or disarms it.
    private func rearm() {
        #if os(Android)
        guard installed, timerFD >= 0 else { return }
        let deadline = timers.nextDeadline
        guard deadline != armedDeadline else { return }
        armedDeadline = deadline
        var spec = itimerspec()
        if let deadline {
            // An absolute time of 0 would disarm it.
            let when = max(deadline, 1)
            spec.it_value.tv_sec = Int(when / 1_000_000_000)
            spec.it_value.tv_nsec = Int(when % 1_000_000_000)
        }
        if timerfd_settime(timerFD, Int32(TFD_TIMER_ABSTIME), &spec, nil) != 0 {
            HostLog.error("MainLooper: timerfd_settime failed: errno \(errno)")
        }
        #endif
    }
}

#if os(Android)
/// The `ALooper` callback for both file descriptors. Returns 1 to stay
/// registered.
private func mainLooperCallback(_ fd: Int32, _ events: Int32, _ context: UnsafeMutableRawPointer?) -> Int32 {
    guard let context else { return 0 }
    Unmanaged<MainLooper>.fromOpaque(context).takeUnretainedValue().handle(fd)
    return 1
}
#endif

/// A `pthread` mutex: `post` is called from any thread.
final class Lock {

    private let mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)

    init() {
        pthread_mutex_init(mutex, nil)
    }

    deinit {
        pthread_mutex_destroy(mutex)
        mutex.deallocate()
    }

    func withLock<R>(_ body: () throws -> R) rethrows -> R {
        pthread_mutex_lock(mutex)
        defer { pthread_mutex_unlock(mutex) }
        return try body()
    }
}
