import DynamicDevice
import DynamicRuntime

/// `Device`: the facts, then the battery and the orientation as they
/// change. The script sets the emulator's battery, and the delegate reports
/// it.
final class DeviceCheck: DeviceDelegate {

    let report: Report

    let device: Device

    private var sawOrientation = false

    init(report: Report) {
        self.report = report
        self.device = DeviceProxy.current()
    }

    func run() {
        report.check(device.systemName() == "Android", "device.systemName Android")
        report.check(device.apiLevel() >= 28, "device.apiLevel \(device.apiLevel())")
        report.check(!device.systemVersion().isEmpty, "device.systemVersion \(device.systemVersion())")
        report.check(!device.model().isEmpty, "device.model \(device.model())")
        report.check(!device.manufacturer().isEmpty, "device.manufacturer \(device.manufacturer())")
        report.check(!device.name().isEmpty, "device.name \(device.name())")
        report.check(device.idiom() == DeviceIdiom.phone.rawValue, "device.idiom phone")
        report.check(device.vendorIdentifier()?.utf8.count == 36, "device.vendorIdentifier is a UUID")
        report.check(device.physicalMemory() > 0, "device.physicalMemory \(device.physicalMemory() >> 20) MB")
        report.check(device.processorCount() > 0, "device.processorCount \(device.processorCount())")
        report.check(device.uptime() > 0, "device.uptime")
        report.note("device.isSimulator \(device.isSimulator())")
        report.check(device.batteryLevel() == -1, "device.batteryLevel unknown before monitoring")
        device.setBatteryMonitoringEnabled(true)
        let level = device.batteryLevel()
        report.check(level >= 0 && level <= 1, "device.batteryLevel \(percent(level))")
        report.check(device.batteryState() != BatteryState.unknown.rawValue, "device.batteryState \(device.batteryState())")
        report.check(ThermalState(rawValue: device.thermalState()) != nil, "device.thermalState \(device.thermalState())")
        report.note("device.isLowPowerModeEnabled \(device.isLowPowerModeEnabled())")
        device.setDelegate(self)
        device.setOrientationUpdatesEnabled(true)
    }

    func didChangeBatteryLevel(_ device: Device, level: Float) {
        report.check(level >= 0 && level <= 1, "device.didChangeBatteryLevel \(percent(level))")
    }

    func didChangeBatteryState(_ device: Device, state: Int32) {
        report.check(BatteryState(rawValue: state) != nil, "device.didChangeBatteryState \(state)")
    }

    func didChangeLowPowerMode(_ device: Device, enabled: Bool) {
        report.note("device.didChangeLowPowerMode \(enabled)")
    }

    func didChangeThermalState(_ device: Device, state: Int32) {
        report.note("device.didChangeThermalState \(state)")
    }

    func didChangeOrientation(_ device: Device, orientation: Int32) {
        guard !sawOrientation else { return }
        sawOrientation = true
        report.check(orientation == DeviceOrientation.portrait.rawValue, "device.didChangeOrientation \(orientation)")
    }

    func didChangeProximityState(_ device: Device, near: Bool) {
        report.note("device.didChangeProximityState \(near)")
    }
}
