import CRuntime
import DynamicRuntime
import ExampleHost
import RuntimeCore
import RuntimeNative
import SwiftJava

/// Phase 0 (`Documentation/Plan.md` §11): AppRuntime's `ExampleApp`, from its
/// sealed `android-*` slice, run inside an Android process.
///
/// The run is the same as AppRuntime's `Packages/LinkedSlice` test on macOS:
/// the host's `ExampleHost` contracts, a manual clock that the run advances
/// itself, and the same expected lines. Phase 1 replaces the manual clock
/// with the main looper's.
enum ExampleAppRun {

    /// The run's report, made once per process: an Activity the system
    /// recreates shows the same report.
    static let report: String = run()

    static func run() -> String {
        let native = NativeRuntime.shared
        native.bindDirectly()
        ExampleHost.lines = []
        ExampleHost.register(in: native)
        // The app may not use Bluetooth; the host may.
        native.capabilities = []
        let clock = ManualClock()
        native.runtime.clock = clock
        let handles = native.runtime.handleCount

        let status = native.start(rt_main, dispatch: rt_dispatch, finalize: rt_finalize)

        // The 1 ms timer resumes the app's main task through the slice's
        // rt_dispatch, which cancels its 1 s sleep.
        let pendingAfterStart = clock.pendingCount
        clock.advance(by: 1_000_000)
        clock.advance(by: 1_000_000_000)

        let lines = ExampleHost.lines
        var problems: [String] = []
        if status != .ok {
            problems.append("rt_main returned \(status)")
        }
        problems += lines.filter { $0.hasPrefix("FAIL") }
        if !lines.contains("beacon refused") {
            problems.append("missing: beacon refused (the app's capabilities)")
        }
        let expectedTail = [
            "done",
            "ok cancel before sleep",
            "async started",
            "ok task value",
            "ok sleep",
            "async done",
            "ok cancel while sleeping",
        ]
        if Array(lines.drop { $0 != "done" }) != expectedTail {
            problems.append("unexpected order after done")
        }
        if pendingAfterStart != 2 {
            problems.append("\(pendingAfterStart) timers after rt_main, expected 2")
        }
        if clock.pendingCount != 0 {
            problems.append("\(clock.pendingCount) timers left")
        }
        if native.runtime.handleCount != handles || Exported.liveCount != 0 {
            problems.append("leaked handles or exports")
        }

        let verdict = problems.isEmpty ? "PASS" : "FAIL"
        return ([verdict + ": ExampleApp, \(lines.count) lines"] + problems + ["", "--"] + lines)
            .joined(separator: "\n")
    }
}

/// The Kotlin side's `NativeHost`, whose `external` methods are implemented
/// here.
@JavaClass("org.pureswift.appruntime.example.NativeHost")
open class NativeHost: JavaObject {}

@JavaImplementation("org.pureswift.appruntime.example.NativeHost")
extension NativeHost {

    /// Runs `ExampleApp` once, and returns its report.
    @JavaMethod
    public func runExampleApp() -> String {
        ExampleAppRun.report
    }
}
