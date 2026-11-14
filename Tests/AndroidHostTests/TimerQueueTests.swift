@testable import AndroidHost
import Testing

/// The main looper's timer ordering, and its jobs and timers off Android.
@Suite struct TimerQueueTests {

    @Test func firesInDeadlineThenSchedulingOrder() {
        var queue = TimerQueue()
        var fired: [String] = []
        _ = queue.schedule(at: 30) { fired.append("c") }
        _ = queue.schedule(at: 10) { fired.append("a") }
        _ = queue.schedule(at: 30) { fired.append("d") }
        _ = queue.schedule(at: 10) { fired.append("b") }
        #expect(queue.nextDeadline == 10)
        #expect(queue.count == 4)

        queue.takeDue(by: 9).forEach { $0() }
        #expect(fired.isEmpty)
        queue.takeDue(by: 10).forEach { $0() }
        #expect(fired == ["a", "b"])
        #expect(queue.nextDeadline == 30)
        queue.takeDue(by: 100).forEach { $0() }
        #expect(fired == ["a", "b", "c", "d"])
        #expect(queue.nextDeadline == nil)
    }

    @Test func cancels() {
        var queue = TimerQueue()
        var fired = 0
        let token = queue.schedule(at: 5) { fired += 1 }
        _ = queue.schedule(at: 6) { fired += 10 }
        queue.cancel(token)
        #expect(queue.nextDeadline == 6)
        queue.takeDue(by: 10).forEach { $0() }
        #expect(fired == 10)
    }

    @Test func saturatesDeadlines() {
        #expect(TimerQueue.deadline(after: 5, from: 10) == 15)
        #expect(TimerQueue.deadline(after: -5, from: 10) == 10)
        #expect(TimerQueue.deadline(after: .max, from: 10) == .max)
    }

    @Test func runsJobsAndDueTimers() {
        let looper = MainLooper()
        var order: [String] = []
        looper.schedule(after: 0) { order.append("timer") }
        looper.schedule(after: 60_000_000_000) { order.append("later") }
        looper.post {
            order.append("job")
            looper.post { order.append("nested job") }
        }
        looper.drain()
        #expect(order == ["job", "timer", "nested job"])
        #expect(looper.pendingTimers == 1)
    }

    @Test func clockSchedulesOnTheLooper() {
        let looper = MainLooper()
        let clock = MainLooperClock(looper: looper)
        var fired = false
        let before = clock.now()
        clock.schedule(after: 0) { fired = true }
        #expect(looper.pendingTimers == 1)
        looper.drain()
        #expect(fired)
        #expect(clock.now() >= before)
    }
}
