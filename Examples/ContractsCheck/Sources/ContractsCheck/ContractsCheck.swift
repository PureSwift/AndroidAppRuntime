import DynamicRuntime
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif

/// What the checks found, one line each: `ok …` or `FAIL …` for a check,
/// `· …` for a note. `Scripts/contracts-check.py` reads them from the
/// screen, and waits for the ones that need something to happen first.
@Observable
final class Report {

    var lines: [String] = []

    func check(_ passed: Bool, _ name: String) {
        lines.append((passed ? "ok " : "FAIL ") + name)
    }

    func note(_ text: String) {
        lines.append("· " + text)
    }
}

/// Every check, started when the app starts.
enum Checks {

    nonisolated(unsafe) static let report = Report()

    nonisolated(unsafe) static var device: DeviceCheck?

    nonisolated(unsafe) static var location: LocationCheck?

    nonisolated(unsafe) static var network: NetworkCheck?

    nonisolated(unsafe) static var bluetooth: BluetoothCheck?

    nonisolated(unsafe) static var motion: MotionCheck?

    nonisolated(unsafe) static var nfc: NFCCheck?

    /// Each prompt after the one before: Android shows one at a time.
    static func startBluetooth() {
        guard bluetooth == nil else { return }
        bluetooth = BluetoothCheck(report: report)
        bluetooth?.run()
    }

    static func startMotion() {
        guard motion == nil else { return }
        motion = MotionCheck(report: report)
        motion?.run()
    }

    static func startNFC() {
        guard nfc == nil else { return }
        nfc = NFCCheck(report: report)
        nfc?.run()
    }

    static func start() {
        device = DeviceCheck(report: report)
        device?.run()
        FormattingCheck.run(report)
        location = LocationCheck(report: report)
        location?.run()
        network = NetworkCheck(report: report)
        network?.run()
    }
}

struct ReportView: View {
    let report: Report

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<report.lines.count) { index in
                    Text(report.lines[index])
                }
            }
            .padding()
        }
    }
}

struct ContractsCheckApp: App {
    let report = Checks.report

    init() {
        Checks.start()
    }

    var body: some Scene {
        WindowGroup {
            ReportView(report: report)
        }
    }
}

/// The app's entry point. The host calls it once after loading the slice.
@_expose(wasm, "rt_main")
@c(rt_main)
public func contractsCheckMain() -> rt_status {
    Runtime.main { ContractsCheckApp.run() }
}

/// "50%" for 0.5.
func percent(_ value: Float) -> String {
    "\(Int((value * 100).rounded()))%"
}
