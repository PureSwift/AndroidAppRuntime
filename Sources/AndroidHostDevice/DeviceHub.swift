import DynamicDevice

/// The system's side of every `AndroidDevice`: the Kotlin `DeviceSystem`,
/// its listeners and what they last heard.
///
/// Each guest object turns its own updates on and off; a system listener
/// stays on while any object wants it. What the listeners hear arrives
/// here from `AndroidHostApp`'s natives and goes to every object. Main
/// thread only.
public final class DeviceHub {

    nonisolated(unsafe) public static let shared = DeviceHub()

    /// Makes the system on first use; `AndroidHostApp` sets it.
    public var makeSystem: (() -> any DeviceSystem)?

    private var _system: (any DeviceSystem)?

    public var system: any DeviceSystem {
        if let _system {
            return _system
        }
        guard let makeSystem else {
            fatalError("DeviceHub.makeSystem isn't set")
        }
        let system = makeSystem()
        _system = system
        return system
    }

    private var cachedFacts: DeviceFacts?

    /// The system's fixed facts, read once.
    public var facts: DeviceFacts {
        if let cachedFacts {
            return cachedFacts
        }
        let facts = system.facts()
        cachedFacts = facts
        return facts
    }

    /// Replaces the system, for tests; resets what the listeners heard.
    public func use(_ system: (any DeviceSystem)?) {
        _system = system
        cachedFacts = nil
        counts = [:]
        devices = []
        orientation = .unknown
        near = false
    }

    private(set) var counts: [DeviceListener: Int] = [:]

    private var devices: [WeakDevice] = []

    /// The accelerometer's last orientation, while it's on.
    private(set) var orientation = DeviceOrientation.unknown

    /// The proximity sensor's last state, while it's on.
    private(set) var near = false

    public init() { }

    // MARK: Objects and listeners

    func add(_ device: AndroidDevice) {
        devices.removeAll { $0.device == nil }
        devices.append(WeakDevice(device: device))
    }

    func remove(_ device: AndroidDevice) {
        devices.removeAll { $0.device == nil || $0.device === device }
    }

    func setListening(_ listener: DeviceListener, _ on: Bool) {
        let count = counts[listener, default: 0] + (on ? 1 : -1)
        precondition(count >= 0)
        counts[listener] = count
        guard count == (on ? 1 : 0) else { return }
        if !on {
            switch listener {
            case .orientation: orientation = .unknown
            case .proximity: near = false
            default: break
            }
        }
        system.setListening(listener, on)
    }

    // MARK: Events

    public func batteryChanged(_ battery: AndroidBattery) {
        let reading = DeviceMappings.battery(battery)
        each { $0.report(battery: reading) }
    }

    public func powerSaveModeChanged(_ enabled: Bool) {
        each { $0.report(lowPowerMode: enabled) }
    }

    public func thermalStatusChanged(_ status: Int32) {
        let state = DeviceMappings.thermalState(status)
        each { $0.report(thermalState: state) }
    }

    /// An accelerometer reading, in m/s².
    public func accelerometer(x: Float, y: Float, z: Float) {
        guard counts[.orientation, default: 0] > 0 else { return }
        let new = DeviceMappings.orientation(x: x, y: y, z: z, last: orientation)
        guard new != orientation else { return }
        orientation = new
        each { $0.report(orientation: new) }
    }

    /// A proximity reading, in cm.
    public func proximity(distance: Float, maximumRange: Float) {
        guard counts[.proximity, default: 0] > 0 else { return }
        let new = DeviceMappings.isNear(distance: distance, maximumRange: maximumRange)
        guard new != near else { return }
        near = new
        each { $0.report(proximity: new) }
    }

    private func each(_ body: (AndroidDevice) -> Void) {
        for device in devices.compactMap(\.device) {
            body(device)
        }
    }
}

private struct WeakDevice {
    weak var device: AndroidDevice?
}
