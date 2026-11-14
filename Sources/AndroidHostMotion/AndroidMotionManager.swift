import AndroidHost
import DynamicMotion
import DynamicRuntime

/// The `MotionManager` contract over the NDK's sensors. Android's units and
/// signs are already the contract's, so samples pass through.
///
/// Device motion is the game rotation vector's attitude with the latest
/// gravity, linear acceleration and gyroscope samples, sent when the
/// rotation vector reports.
public final class AndroidMotionManager: MotionManager, SensorClient {

    let hub: MotionHub

    /// Kept strongly (`Plan.md` §6).
    let delegate: any MotionManagerDelegate

    private(set) var active: Set<MotionSensor> = []

    private var gravity: [Float] = [0, 0, 0]

    private var linearAcceleration: [Float] = [0, 0, 0]

    private var rotationRate: [Float] = [0, 0, 0]

    init(delegate: any MotionManagerDelegate, hub: MotionHub = .shared) {
        self.delegate = delegate
        self.hub = hub
    }

    deinit {
        for sensor in active {
            for type in MotionMapping.sensorTypes(sensor) {
                hub.unsubscribe(self, from: type)
            }
        }
    }

    public static func isAvailable(_ sensor: Int32) -> Bool {
        guard let sensor = MotionSensor(rawValue: sensor) else { return false }
        return MotionMapping.sensorTypes(sensor).allSatisfy(MotionHub.shared.system.hasSensor)
    }

    public static func make(_ delegate: any MotionManagerDelegate) -> AndroidMotionManager {
        AndroidMotionManager(delegate: delegate)
    }

    public func start(_ sensor: Int32, interval: Double) {
        guard let motion = MotionSensor(rawValue: sensor) else {
            delegate.didFail(self, sensor: sensor, error: MotionError.unavailable.rawValue)
            return
        }
        let types = MotionMapping.sensorTypes(motion)
        guard types.allSatisfy(hub.system.hasSensor) else {
            delegate.didFail(self, sensor: sensor, error: MotionError.unavailable.rawValue)
            return
        }
        stop(sensor)
        for type in types {
            let period = MotionMapping.period(interval: interval, minimumDelay: hub.system.minimumDelay(type))
            guard hub.subscribe(self, to: type, period: period) else {
                for started in types {
                    hub.unsubscribe(self, from: started)
                }
                delegate.didFail(self, sensor: sensor, error: MotionError.unknown.rawValue)
                return
            }
        }
        active.insert(motion)
    }

    public func stop(_ sensor: Int32) {
        guard let motion = MotionSensor(rawValue: sensor), active.remove(motion) != nil else { return }
        // Another active sensor may share a type (device motion's gyroscope).
        let kept = Set(active.flatMap(MotionMapping.sensorTypes))
        for type in MotionMapping.sensorTypes(motion) where !kept.contains(type) {
            hub.unsubscribe(self, from: type)
        }
    }

    public func isActive(_ sensor: Int32) -> Bool {
        MotionSensor(rawValue: sensor).map(active.contains) ?? false
    }

    public func minimumInterval(_ sensor: Int32) -> Double {
        guard let motion = MotionSensor(rawValue: sensor) else { return 0 }
        let delay = MotionMapping.sensorTypes(motion).map(hub.system.minimumDelay).max() ?? 0
        return Double(MotionMapping.period(interval: 0, minimumDelay: delay)) / 1_000_000
    }

    func received(_ sample: SensorSample) {
        let v = sample.values.map(Double.init) + [0, 0, 0]
        switch sample.type {
        case SensorType.accelerometer where active.contains(.accelerometer):
            delegate.didUpdateAcceleration(self, x: v[0], y: v[1], z: v[2], timestamp: sample.timestamp)
        case SensorType.magneticField where active.contains(.magnetometer):
            delegate.didUpdateMagneticField(self, x: v[0], y: v[1], z: v[2],
                                            accuracy: MotionMapping.magneticAccuracy(sample.status).rawValue,
                                            timestamp: sample.timestamp)
        case SensorType.gyroscope:
            rotationRate = Array(sample.values.prefix(3))
            if active.contains(.gyroscope) {
                delegate.didUpdateRotationRate(self, x: v[0], y: v[1], z: v[2], timestamp: sample.timestamp)
            }
        case SensorType.gravity:
            gravity = Array(sample.values.prefix(3))
        case SensorType.linearAcceleration:
            linearAcceleration = Array(sample.values.prefix(3))
        case SensorType.gameRotationVector where active.contains(.deviceMotion):
            let attitude = MotionMapping.quaternion(sample.values)
            let g = gravity.map(Double.init), a = linearAcceleration.map(Double.init), r = rotationRate.map(Double.init)
            delegate.didUpdateDeviceMotion(
                self,
                attitudeX: attitude.x, attitudeY: attitude.y, attitudeZ: attitude.z, attitudeW: attitude.w,
                gravityX: g[0], gravityY: g[1], gravityZ: g[2],
                userAccelerationX: a[0], userAccelerationY: a[1], userAccelerationZ: a[2],
                rotationRateX: r[0], rotationRateY: r[1], rotationRateZ: r[2],
                timestamp: sample.timestamp
            )
        default:
            break
        }
    }
}
