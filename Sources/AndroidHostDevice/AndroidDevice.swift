import AndroidHost
import DynamicDevice
import DynamicRuntime

/// The `Device` contract over `Build`, `BatteryManager`, `PowerManager` and
/// `SensorManager` (`Plan.md` §6.2), through `DeviceHub`.
///
/// `current()` makes a new object each time, so each guest user has its own
/// delegate and its own opt-in updates. An object's battery and
/// orientation getters read as unknown until it turns its own on, as the
/// contract says.
///
/// Changes reach the delegate on the main thread, and only when the value
/// differs from the last one reported:
/// - Battery Saver and the thermal status while a delegate is set;
/// - battery, orientation and proximity while also turned on.
///
/// Proximity monitoring reports the sensor only: unlike iOS, Android
/// doesn't turn the screen off for it without a wake lock.
public final class AndroidDevice: Device {

    let hub: DeviceHub

    /// Kept strongly (`Plan.md` §6): the guest's object lives until the
    /// delegate is replaced or this object goes away.
    private(set) var delegate: (any DeviceDelegate)?

    private(set) var batteryMonitoring = false

    private(set) var orientationUpdates = false

    private(set) var proximityMonitoring = false

    /// The last values reported, or read when the updates started.
    private var lastBattery = BatteryReading.none

    private var lastLowPowerMode = false

    private var lastThermalState = ThermalState.nominal

    private var lastOrientation = DeviceOrientation.unknown

    private var lastProximity = false

    init(hub: DeviceHub = .shared) {
        self.hub = hub
        hub.add(self)
    }

    deinit {
        if delegate != nil {
            hub.setListening(.power, false)
        }
        if batteryMonitoring {
            hub.setListening(.battery, false)
        }
        if orientationUpdates {
            hub.setListening(.orientation, false)
        }
        if proximityMonitoring {
            hub.setListening(.proximity, false)
        }
        hub.remove(self)
    }

    public static func current() -> AndroidDevice {
        AndroidDevice()
    }

    public func setDelegate(_ delegate: (any DeviceDelegate)?) {
        if (self.delegate == nil) != (delegate == nil) {
            hub.setListening(.power, delegate != nil)
        }
        self.delegate = delegate
        guard delegate != nil else { return }
        lastLowPowerMode = isLowPowerModeEnabled()
        lastThermalState = ThermalState(rawValue: thermalState()) ?? .nominal
        lastBattery = batteryReading
        lastOrientation = DeviceOrientation(rawValue: orientation()) ?? .unknown
        lastProximity = proximityState()
    }

    // MARK: Identity

    var facts: DeviceFacts {
        hub.facts
    }

    public func name() -> String {
        hub.system.name()
    }

    public func model() -> String {
        facts.model
    }

    /// `Build.MODEL`, as the contract says; on Pixels it's also the
    /// marketing name.
    public func modelIdentifier() -> String {
        facts.model
    }

    public func manufacturer() -> String {
        DeviceMappings.manufacturer(facts.manufacturer)
    }

    public func systemName() -> String {
        "Android"
    }

    public func systemVersion() -> String {
        facts.release
    }

    public func apiLevel() -> Int32 {
        facts.apiLevel
    }

    public func idiom() -> Int32 {
        DeviceMappings.idiom(facts).rawValue
    }

    public func vendorIdentifier() -> String? {
        facts.vendorIdentifier
    }

    public func isSimulator() -> Bool {
        DeviceMappings.isEmulator(facts)
    }

    // MARK: Resources

    public func physicalMemory() -> Int64 {
        facts.physicalMemory
    }

    public func processorCount() -> Int32 {
        facts.processorCount
    }

    /// `CLOCK_BOOTTIME`, which keeps counting while the device sleeps, like
    /// the host's `Clock`.
    public func uptime() -> Int64 {
        MainLooper.now() / 1_000_000
    }

    // MARK: Power

    public func setBatteryMonitoringEnabled(_ enabled: Bool) {
        guard enabled != batteryMonitoring else { return }
        batteryMonitoring = enabled
        hub.setListening(.battery, enabled)
        lastBattery = batteryReading
    }

    public func batteryLevel() -> Float {
        batteryReading.level
    }

    public func batteryState() -> Int32 {
        batteryReading.state.rawValue
    }

    public func isLowPowerModeEnabled() -> Bool {
        hub.system.isPowerSaveMode()
    }

    public func thermalState() -> Int32 {
        DeviceMappings.thermalState(hub.system.thermalStatus()).rawValue
    }

    /// The battery now, or `.none` while this object's monitoring is off.
    var batteryReading: BatteryReading {
        guard batteryMonitoring else {
            return .none
        }
        return DeviceMappings.battery(hub.system.battery())
    }

    // MARK: Orientation and proximity

    public func setOrientationUpdatesEnabled(_ enabled: Bool) {
        guard enabled != orientationUpdates else { return }
        orientationUpdates = enabled
        hub.setListening(.orientation, enabled)
        lastOrientation = DeviceOrientation(rawValue: orientation()) ?? .unknown
    }

    /// Unknown until the accelerometer's first reading.
    public func orientation() -> Int32 {
        guard orientationUpdates else {
            return DeviceOrientation.unknown.rawValue
        }
        return hub.orientation.rawValue
    }

    public func setProximityMonitoringEnabled(_ enabled: Bool) {
        guard enabled != proximityMonitoring else { return }
        guard !enabled || hub.system.hasProximitySensor() else { return }
        proximityMonitoring = enabled
        hub.setListening(.proximity, enabled)
        lastProximity = proximityState()
    }

    /// False on devices without a sensor, where monitoring stays off.
    public func isProximityMonitoringEnabled() -> Bool {
        proximityMonitoring
    }

    public func proximityState() -> Bool {
        proximityMonitoring && hub.near
    }

    // MARK: Changes

    /// Tells the delegate what changed in the battery, if this object
    /// monitors it.
    func report(battery reading: BatteryReading) {
        guard batteryMonitoring else { return }
        let last = lastBattery
        lastBattery = reading
        if reading.level != last.level {
            delegate?.didChangeBatteryLevel(self, level: reading.level)
        }
        if reading.state != last.state {
            delegate?.didChangeBatteryState(self, state: reading.state.rawValue)
        }
    }

    func report(lowPowerMode enabled: Bool) {
        guard delegate != nil, enabled != lastLowPowerMode else { return }
        lastLowPowerMode = enabled
        delegate?.didChangeLowPowerMode(self, enabled: enabled)
    }

    func report(thermalState state: ThermalState) {
        guard delegate != nil, state != lastThermalState else { return }
        lastThermalState = state
        delegate?.didChangeThermalState(self, state: state.rawValue)
    }

    func report(orientation: DeviceOrientation) {
        guard orientationUpdates, orientation != lastOrientation else { return }
        lastOrientation = orientation
        delegate?.didChangeOrientation(self, orientation: orientation.rawValue)
    }

    func report(proximity near: Bool) {
        guard proximityMonitoring, near != lastProximity else { return }
        lastProximity = near
        delegate?.didChangeProximityState(self, near: near)
    }
}

/// The `DynamicDevice` contracts (`Plan.md` §6.2). `Device` needs no
/// capability, so this module has no permission providers.
public enum AndroidHostDevice: HostModule {

    public static var contracts: [ContractDescriptor] {
        [DeviceProxy.descriptor, DeviceDelegateProxy.descriptor]
    }

    public static func register(in registrar: some ContractRegistrar) {
        DeviceProxy.register(AndroidDevice.self, in: registrar)
        DeviceDelegateProxy.registerInterface(in: registrar)
    }
}
