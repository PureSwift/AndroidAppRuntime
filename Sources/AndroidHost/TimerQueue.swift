/// The main looper's timers, soonest first; timers with the same deadline
/// fire in the order they were scheduled.
///
/// Platform-neutral, so its ordering is tested on macOS; `MainLooper` keeps
/// one and arms its `timerfd` for `nextDeadline`.
public struct TimerQueue {

    /// A scheduled timer, for `cancel`.
    public struct Token: Hashable, Sendable {
        let id: UInt64
    }

    private struct Timer {
        let deadline: Int64
        let token: Token
        let body: () -> Void
    }

    private var timers: [Timer] = []

    private var nextID: UInt64 = 0

    public init() { }

    /// Timers that haven't fired.
    public var count: Int {
        timers.count
    }

    /// When the soonest timer is due, if any.
    public var nextDeadline: Int64? {
        timers.first?.deadline
    }

    /// Adds a timer due at `deadline`.
    public mutating func schedule(at deadline: Int64, _ body: @escaping () -> Void) -> Token {
        let token = Token(id: nextID)
        nextID &+= 1
        let index = timers.firstIndex { $0.deadline > deadline } ?? timers.endIndex
        timers.insert(Timer(deadline: deadline, token: token, body: body), at: index)
        return token
    }

    /// Removes a timer that hasn't fired.
    public mutating func cancel(_ token: Token) {
        timers.removeAll { $0.token == token }
    }

    /// Removes and returns the timers due by `now`, in firing order. Timers
    /// that firing schedules wait for the next call.
    public mutating func takeDue(by now: Int64) -> [() -> Void] {
        let due = timers.prefix { $0.deadline <= now }
        timers.removeFirst(due.count)
        return due.map(\.body)
    }

    /// A deadline `nanoseconds` after `now`, saturating.
    public static func deadline(after nanoseconds: Int64, from now: Int64) -> Int64 {
        let (deadline, overflow) = now.addingReportingOverflow(max(nanoseconds, 0))
        return overflow ? .max : deadline
    }
}
