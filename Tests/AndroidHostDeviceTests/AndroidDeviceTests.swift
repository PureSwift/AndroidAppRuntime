@testable import AndroidHostDevice
import DynamicDevice
import DynamicRuntime
import Testing

/// A device the tests set up.
final class FakeDeviceSystem: DeviceSystem {

    var deviceFacts = DeviceFacts(
        model: "Pixel 8", manufacturer: "Google", release: "14", apiLevel: 34, uiModeType: 1,
        smallestWidthDP: 411, isPC: false, fingerprint: "google/shiba/shiba:14/AP1A/1:user/release-keys",
        hardware: "shiba", product: "shiba", vendorIdentifier: "6F9619FF-8B86-3011-B42D-00C04FC964FF",
        physicalMemory: 8 << 30, processorCount: 9
    )

    var deviceName = "Ada's Pixel"

    var batteryValue: AndroidBattery? = AndroidBattery(level: 80, scale: 100, status: 3, plugged: 0, present: true)

    var powerSave = false

    var thermal: Int32 = 0

    var proximitySensor = true

    var listening: Set<DeviceListener> = []

    var factReads = 0

    func facts() -> DeviceFacts {
        factReads += 1
        return deviceFacts
    }

    func name() -> String { deviceName }

    func battery() -> AndroidBattery? { batteryValue }

    func isPowerSaveMode() -> Bool { powerSave }

    func thermalStatus() -> Int32 { thermal }

    func hasProximitySensor() -> Bool { proximitySensor }

    func setListening(_ listener: DeviceListener, _ on: Bool) {
        if on {
            listening.insert(listener)
        } else {
            listening.remove(listener)
        }
    }
}

/// A guest-side delegate.
final class RecordingDeviceDelegate: DeviceDelegate {

    var events: [String] = []

    func didChangeBatteryLevel(_ device: any Device, level: Float) {
        events.append("level \(level)")
    }

    func didChangeBatteryState(_ device: any Device, state: Int32) {
        events.append("state \(state)")
    }

    func didChangeLowPowerMode(_ device: any Device, enabled: Bool) {
        events.append("low power \(enabled)")
    }

    func didChangeThermalState(_ device: any Device, state: Int32) {
        events.append("thermal \(state)")
    }

    func didChangeOrientation(_ device: any Device, orientation: Int32) {
        events.append("orientation \(orientation)")
    }

    func didChangeProximityState(_ device: any Device, near: Bool) {
        events.append("proximity \(near)")
    }
}

/// Serialized: the hub is shared.
@Suite(.serialized) struct AndroidDeviceTests {

    let system = FakeDeviceSystem()

    init() {
        DeviceHub.shared.use(system)
    }

    @Test func readsIdentity() {
        let device = AndroidDevice.current()
        #expect(device.name() == "Ada's Pixel")
        #expect(device.model() == "Pixel 8")
        #expect(device.modelIdentifier() == "Pixel 8")
        #expect(device.manufacturer() == "Google")
        #expect(device.systemName() == "Android")
        #expect(device.systemVersion() == "14")
        #expect(device.apiLevel() == 34)
        #expect(device.idiom() == DeviceIdiom.phone.rawValue)
        #expect(device.vendorIdentifier() == "6F9619FF-8B86-3011-B42D-00C04FC964FF")
        #expect(!device.isSimulator())
        #expect(device.physicalMemory() == 8 << 30)
        #expect(device.processorCount() == 9)
        #expect(system.factReads == 1, "the facts are read once")
    }

    @Test func mapsIdentity() {
        var facts = system.deviceFacts
        #expect(DeviceMappings.manufacturer("samsung") == "Samsung")
        #expect(DeviceMappings.manufacturer("") == "")
        facts.smallestWidthDP = 600
        #expect(DeviceMappings.idiom(facts) == .pad)
        facts.isPC = true
        #expect(DeviceMappings.idiom(facts) == .desktop)
        for (type, idiom) in [(Int32(4), DeviceIdiom.tv), (3, .car), (6, .watch), (7, .vision), (2, .desktop)] {
            facts.uiModeType = type
            #expect(DeviceMappings.idiom(facts) == idiom)
        }
        facts.hardware = "ranchu"
        #expect(DeviceMappings.isEmulator(facts))
        facts.hardware = "shiba"
        facts.product = "sdk_gphone64_arm64"
        #expect(DeviceMappings.isEmulator(facts))
    }

    @Test func mapsBatteryAndThermalState() {
        func reading(_ level: Int32, _ status: Int32, _ plugged: Int32, present: Bool = true) -> BatteryReading {
            DeviceMappings.battery(AndroidBattery(level: level, scale: 100, status: status, plugged: plugged, present: present))
        }
        #expect(reading(50, 3, 0) == BatteryReading(level: 0.5, state: .unplugged))
        #expect(reading(50, 2, 1) == BatteryReading(level: 0.5, state: .charging))
        // Plugged in and held below full (adaptive charging) still charges.
        #expect(reading(80, 4, 2) == BatteryReading(level: 0.8, state: .charging))
        #expect(reading(100, 2, 1) == BatteryReading(level: 1, state: .full))
        #expect(reading(97, 5, 1) == BatteryReading(level: 0.97, state: .full))
        #expect(reading(50, 3, 0, present: false) == .none)
        #expect(DeviceMappings.battery(nil) == .none)
        #expect(DeviceMappings.battery(AndroidBattery(level: -1, scale: 100, status: 2, plugged: 1, present: true)).level == -1)
        #expect([0, 1, 2, 3, 4, 5, 6].map { DeviceMappings.thermalState($0) }
                == [.nominal, .nominal, .fair, .serious, .critical, .critical, .critical])
    }

    @Test func mapsOrientationAndProximity() {
        func orientation(_ x: Float, _ y: Float, _ z: Float, last: DeviceOrientation = .unknown) -> DeviceOrientation {
            DeviceMappings.orientation(x: x, y: y, z: z, last: last)
        }
        #expect(orientation(0, 9.8, 0) == .portrait)
        #expect(orientation(0, -9.8, 0) == .portraitUpsideDown)
        #expect(orientation(9.8, 0, 0) == .landscapeLeft)
        #expect(orientation(-9.8, 0, 0) == .landscapeRight)
        #expect(orientation(0.3, 0.5, 9.7) == .faceUp)
        #expect(orientation(0, 0, -9.8) == .faceDown)
        // Tilted back but upright is still portrait.
        #expect(orientation(0.5, 6.5, 7) == .portrait)
        // Diagonals and free fall keep the last.
        #expect(orientation(6.9, 6.9, 0, last: .portrait) == .portrait)
        #expect(orientation(0.1, 0.2, 0.3, last: .landscapeLeft) == .landscapeLeft)
        #expect(DeviceMappings.isNear(distance: 0, maximumRange: 5))
        #expect(!DeviceMappings.isNear(distance: 5, maximumRange: 5))
        #expect(DeviceMappings.isNear(distance: 3, maximumRange: 10))
        #expect(!DeviceMappings.isNear(distance: 8, maximumRange: 10))
    }

    @Test func readsUnknownUntilEnabled() {
        let device = AndroidDevice.current()
        #expect(device.batteryLevel() == -1)
        #expect(device.batteryState() == BatteryState.unknown.rawValue)
        device.setBatteryMonitoringEnabled(true)
        #expect(device.batteryLevel() == 0.8)
        #expect(device.batteryState() == BatteryState.unplugged.rawValue)
        #expect(device.orientation() == DeviceOrientation.unknown.rawValue)
        device.setOrientationUpdatesEnabled(true)
        DeviceHub.shared.accelerometer(x: 0, y: 9.8, z: 0)
        #expect(device.orientation() == DeviceOrientation.portrait.rawValue)
    }

    @Test func countsListenersAcrossObjects() {
        var first: AndroidDevice? = AndroidDevice.current()
        let second = AndroidDevice.current()
        first?.setBatteryMonitoringEnabled(true)
        second.setBatteryMonitoringEnabled(true)
        first?.setDelegate(RecordingDeviceDelegate())
        #expect(system.listening == [.battery, .power])
        second.setBatteryMonitoringEnabled(false)
        #expect(system.listening == [.battery, .power])
        first = nil
        #expect(system.listening.isEmpty, "a released object turns its listeners off")
    }

    @Test func proximityNeedsASensor() {
        system.proximitySensor = false
        let device = AndroidDevice.current()
        device.setProximityMonitoringEnabled(true)
        #expect(!device.isProximityMonitoringEnabled())
        #expect(system.listening.isEmpty)
        system.proximitySensor = true
        device.setProximityMonitoringEnabled(true)
        #expect(device.isProximityMonitoringEnabled())
        DeviceHub.shared.proximity(distance: 0, maximumRange: 5)
        #expect(device.proximityState())
    }

    @Test func reportsChangesToTheDelegate() {
        let device = AndroidDevice.current()
        let delegate = RecordingDeviceDelegate()
        device.setDelegate(delegate)
        let hub = DeviceHub.shared
        // Battery changes need monitoring.
        hub.batteryChanged(AndroidBattery(level: 70, scale: 100, status: 3, plugged: 0, present: true))
        device.setBatteryMonitoringEnabled(true)
        hub.batteryChanged(AndroidBattery(level: 80, scale: 100, status: 2, plugged: 1, present: true))
        hub.batteryChanged(AndroidBattery(level: 90, scale: 100, status: 2, plugged: 1, present: true))
        hub.powerSaveModeChanged(true)
        hub.powerSaveModeChanged(true)
        hub.thermalStatusChanged(1)
        hub.thermalStatusChanged(3)
        hub.accelerometer(x: 9.8, y: 0, z: 0)
        device.setOrientationUpdatesEnabled(true)
        hub.accelerometer(x: 9.8, y: 0, z: 0)
        hub.accelerometer(x: 9.7, y: 0.2, z: 0)
        device.setProximityMonitoringEnabled(true)
        hub.proximity(distance: 0, maximumRange: 5)
        hub.proximity(distance: 5, maximumRange: 5)
        #expect(delegate.events == [
            "state 2",
            "level 0.9",
            "low power true",
            "thermal 2",
            "orientation 3",
            "proximity true",
            "proximity false",
        ])
    }

    @Test func registersEveryContract() {
        #expect(AndroidHostDevice.contracts == [DeviceProxy.descriptor, DeviceDelegateProxy.descriptor])
        #expect(AndroidHostDevice.permissionProviders().isEmpty)
    }
}
