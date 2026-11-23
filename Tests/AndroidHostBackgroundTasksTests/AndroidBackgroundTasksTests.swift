import Testing
import AndroidHost
import DynamicBackgroundTasks
import DynamicRuntime
import RuntimeBackgroundTasks
@testable import AndroidHostBackgroundTasks

/// The Kotlin side's `WorkManager`, in memory: the calls the scheduler
/// made, and what the workers were told.
final class ScriptedWork: BackgroundTaskSystem {

    var isRestricted = false

    var calls: [String] = []

    /// What `submit` answers.
    var refusing = false

    var finished: [(token: Int32, success: Bool)] = []

    func restricted() -> Bool { isRestricted }

    func submit(_ identifier: String, kind: Int32, earliest: Double, interval: Double, requirements: Int32) -> Int32 {
        calls.append("submit \(identifier) \(kind) \(earliest) \(interval) \(requirements)")
        return refusing ? -1 : 0
    }

    func cancel(_ identifier: String) {
        calls.append("cancel \(identifier)")
    }

    func cancelAll() {
        calls.append("cancelAll")
    }

    func pending(_ request: Int32) {
        calls.append("pending \(request)")
    }

    func finished(_ token: Int32, success: Bool) {
        finished.append((token, success))
    }
}

/// The guest's side: its delegate and its callbacks.
final class Guest: BackgroundTasksDelegate, BackgroundCallback {

    var heard: [String] = []

    /// Completes each run as it's told of it, with this.
    var completes: Bool?

    func run(_ identifier: String, run: Int32) {
        heard.append("run \(identifier)")
        if let completes {
            HostBackgroundTasks.shared().complete(run, success: completes)
        }
    }

    func didExpire(_ run: Int32) {
        heard.append("expire")
    }

    func didExpireActivity(_ activity: Int32) {
        heard.append("expire activity")
    }

    func didComplete() {
        heard.append("complete")
    }

    func didList(_ identifiers: [String]) {
        heard.append("list \(identifiers)")
    }

    func didFail(_ error: Int32) {
        heard.append("fail \(error)")
    }
}

/// `HostBackgroundTasks` over `AndroidBackgroundScheduler`, over a
/// scripted `WorkManager`. Serialized: the contract is a singleton.
@Suite(.serialized) final class AndroidBackgroundTasksTests {

    let work = ScriptedWork()

    let guest = Guest()

    var tasks: HostBackgroundTasks { HostBackgroundTasks.shared() }

    init() {
        HostBackgroundTasks.reset()
        AndroidHostBackgroundTasks.configure(work, declared: AndroidHostBackgroundTasks.declared([
            ["Identifier": "org.example.sync", "Kind": "refresh"],
            ["Identifier": "org.example.index", "Kind": "processing"],
        ]))
        // At once, in place of the main looper.
        HostBackgroundTasks.deliver = { $0() }
        HostBackgroundTasks.after = { _, job in job() }
    }

    deinit {
        HostBackgroundTasks.reset()
        BackgroundTaskHub.shared.scheduler = nil
    }

    @Test func readsTheManifestsTasks() {
        let declared = AndroidHostBackgroundTasks.declared([
            ["Identifier": "a", "Kind": "refresh"],
            ["Identifier": "b", "Kind": "processing"],
            ["Identifier": "c", "Kind": "sometimes"],
            ["Kind": "refresh"],
        ])
        #expect(declared == ["a": .refresh, "b": .processing])
    }

    @Test func theStatusIsAndroidsRestriction() {
        #expect(tasks.status() == PermissionStatus.granted.rawValue)
        work.isRestricted = true
        #expect(tasks.status() == PermissionStatus.denied.rawValue)
    }

    @Test func asksWorkManagerForADeclaredTask() {
        tasks.submit("org.example.sync", kind: 0, earliest: 60, interval: 1800, requirements: 1, callback: guest)
        tasks.submit("org.example.index", kind: 1, earliest: 0, interval: 0, requirements: 2, callback: guest)
        #expect(work.calls == ["submit org.example.sync 0 60.0 1800.0 1", "submit org.example.index 1 0.0 0.0 2"])
        #expect(guest.heard == ["complete", "complete"])
    }

    @Test func refusesWhatTheManifestDoesntSay() {
        tasks.submit("org.example.other", kind: 0, earliest: 0, interval: 0, requirements: 0, callback: guest)
        tasks.submit("org.example.sync", kind: 1, earliest: 0, interval: 0, requirements: 0, callback: guest)
        tasks.submit("org.example.sync", kind: 0, earliest: 0, interval: 60, requirements: 0, callback: guest)
        #expect(work.calls == [])
        #expect(guest.heard == ["fail \(BackgroundError.notDeclared.rawValue)", "fail \(BackgroundError.notDeclared.rawValue)",
                                "fail \(BackgroundError.invalid.rawValue)"])
    }

    @Test func aRequestWorkManagerRefusesFails() {
        work.refusing = true
        tasks.submit("org.example.sync", kind: 0, earliest: 0, interval: 0, requirements: 0, callback: guest)
        #expect(guest.heard == ["fail \(BackgroundError.unknown.rawValue)"])
    }

    @Test func cancelsAndListsThroughWorkManager() {
        tasks.cancel("org.example.sync")
        tasks.cancelAll()
        tasks.pending(guest)
        #expect(work.calls == ["cancel org.example.sync", "cancelAll", "pending 1"])
        #expect(guest.heard == [])
        BackgroundTaskHub.shared.listed(1, identifiers: "org.example.sync\norg.example.index")
        #expect(guest.heard == ["list [\"org.example.sync\", \"org.example.index\"]"])
        // Nothing pending is an empty list; a second answer goes nowhere.
        tasks.pending(guest)
        BackgroundTaskHub.shared.listed(2, identifiers: "")
        BackgroundTaskHub.shared.listed(2, identifiers: "late")
        #expect(guest.heard.last == "list []")
    }

    @Test func aRunReachesTheGuestAndItsCompletionTheWorker() {
        tasks.setDelegate(guest)
        guest.completes = true
        _ = BackgroundTaskHub.shared.run("org.example.sync", token: 7)
        #expect(guest.heard == ["run org.example.sync"])
        #expect(work.finished.map(\.token) == [7])
        #expect(work.finished.map(\.success) == [true])
        // WorkManager repeats a periodic request by itself: nothing is asked again.
        #expect(work.calls == [])
    }

    @Test func aRunWithNoDelegateFails() {
        _ = BackgroundTaskHub.shared.run("org.example.sync", token: 3)
        #expect(work.finished.map(\.token) == [3])
        #expect(work.finished.map(\.success) == [false])
    }

    @Test func aStoppedRunIsToldAndFailsAfterItsGrace() {
        tasks.setDelegate(guest)
        let run = BackgroundTaskHub.shared.run("org.example.sync", token: 4)
        #expect(work.finished.isEmpty)
        BackgroundTaskHub.shared.expire(run)
        #expect(guest.heard == ["run org.example.sync", "expire"])
        #expect(work.finished.map(\.success) == [false])
        // Completing it afterwards changes nothing.
        tasks.complete(run, success: true)
        #expect(work.finished.count == 1)
    }

    @Test func anActivityHasAlreadyExpired() {
        #expect(tasks.beginActivity("Saving") == 0)
        #expect(tasks.timeRemaining() == -1)
    }
}
