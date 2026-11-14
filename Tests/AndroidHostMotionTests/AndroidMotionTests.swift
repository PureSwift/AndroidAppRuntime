import AndroidHost
@testable import AndroidHostMotion
import DynamicMotion
import DynamicRuntime
import Testing

/// Sensors the tests set up.
final class FakeSensorSystem: SensorSystem {

    var sensors: Set<Int32> = [1, 2, 4, 6, 9, 10, 15, 19]
    var delays: [Int32: Int32] = [1: 2_500, 4: 2_500, 6: 200_000]
    var enabled: [Int32: Int32] = [:]
    var refuse: Set<Int32> = []

    func hasSensor(_ type: Int32) -> Bool { sensors.contains(type) }
    func minimumDelay(_ type: Int32) -> Int32 { delays[type] ?? 0 }

    func enable(_ type: Int32, period: Int32) -> Bool {
        guard !refuse.contains(type) else { return false }
        enabled[type] = period
        return true
    }

    func disable(_ type: Int32) { enabled[type] = nil }
}

final class FakePermissions: PermissionSystem {
    var apiLevel: Int32 = 34
    var granted: Set<String> = []
    var requests: [[String]] = []
    func isGranted(_ permission: String) -> Bool { granted.contains(permission) }
    func wasRequested(_ permission: String) -> Bool { false }
    func isDeclared(_ permission: String) -> Bool { true }
    func hasFeature(_ feature: String) -> Bool { true }
    func request(_ permissions: [String], id: Int32) -> Bool {
        requests.append(permissions)
        return true
    }
}

final class RecordingMotion: MotionManagerDelegate, AltimeterDelegate, PedometerDelegate, ActivityRecognizerDelegate {

    var events: [String] = []
    var motions: [DeviceMotion] = []

    func didUpdateAcceleration(_ manager: any MotionManager, x: Double, y: Double, z: Double, timestamp: Int64) {
        events.append("acceleration \(z) \(timestamp)")
    }

    func didUpdateRotationRate(_ manager: any MotionManager, x: Double, y: Double, z: Double, timestamp: Int64) {
        events.append("rotation \(x)")
    }

    func didUpdateMagneticField(_ manager: any MotionManager, x: Double, y: Double, z: Double, accuracy: Int32, timestamp: Int64) {
        events.append("magnetic \(accuracy)")
    }

    func didUpdateDeviceMotion(_ manager: any MotionManager, attitudeX: Double, attitudeY: Double, attitudeZ: Double, attitudeW: Double,
                               gravityX: Double, gravityY: Double, gravityZ: Double, userAccelerationX: Double, userAccelerationY: Double,
                               userAccelerationZ: Double, rotationRateX: Double, rotationRateY: Double, rotationRateZ: Double, timestamp: Int64) {
        motions.append(DeviceMotion(
            attitude: Quaternion(x: attitudeX, y: attitudeY, z: attitudeZ, w: attitudeW),
            gravity: Vector3(x: gravityX, y: gravityY, z: gravityZ),
            userAcceleration: Vector3(x: userAccelerationX, y: userAccelerationY, z: userAccelerationZ),
            rotationRate: Vector3(x: rotationRateX, y: rotationRateY, z: rotationRateZ), timestamp: timestamp))
    }

    func didFail(_ manager: any MotionManager, sensor: Int32, error: Int32) {
        events.append("fail \(sensor) \(error)")
    }

    func didChangeAuthorization(_ altimeter: any Altimeter, status: Int32) { events.append("altimeter authorization \(status)") }

    func didUpdate(_ altimeter: any Altimeter, pressure: Double, relativeAltitude: Double, timestamp: Int64) {
        events.append("altitude \((pressure * 100).rounded() / 100) \(relativeAltitude.rounded())")
    }

    func didFail(_ altimeter: any Altimeter, error: Int32) { events.append("altimeter fail \(error)") }

    func didChangeAuthorization(_ pedometer: any Pedometer, status: Int32) { events.append("pedometer authorization \(status)") }

    func didUpdate(_ pedometer: any Pedometer, steps: Int64, distance: Double, floorsAscended: Int32, floorsDescended: Int32, start: Int64, end: Int64) {
        events.append("steps \(steps) \(distance.isNaN) \(floorsAscended)")
    }

    func didQuery(_ pedometer: any Pedometer, steps: Int64, distance: Double, floorsAscended: Int32, floorsDescended: Int32, start: Int64, end: Int64, error: Int32) {
        events.append("query \(error)")
    }

    func didFail(_ pedometer: any Pedometer, error: Int32) { events.append("pedometer fail \(error)") }

    func didChangeAuthorization(_ recognizer: any ActivityRecognizer, status: Int32) { events.append("activity authorization \(status)") }

    func didUpdateActivity(_ recognizer: any ActivityRecognizer, activity: Int32, confidence: Int32, timestamp: Int64) {}

    func didFail(_ recognizer: any ActivityRecognizer, error: Int32) { events.append("activity fail \(error)") }
}

/// Serialized: the hub and `AndroidPermissions` are shared.
@Suite(.serialized) struct AndroidMotionTests {

    let system = FakeSensorSystem()
    let permissions = FakePermissions()
    let hub = MotionHub.shared

    init() {
        AndroidPermissions.reset()
        AndroidPermissions.system = permissions
        hub.use(system)
    }

    @Test func maps() {
        #expect(MotionMapping.period(interval: 0.01, minimumDelay: 2_500) == 10_000)
        #expect(MotionMapping.period(interval: 0.001, minimumDelay: 2_500) == 5_000, "200 Hz at most")
        #expect(MotionMapping.period(interval: 0.001, minimumDelay: 20_000) == 20_000)
        #expect(MotionMapping.period(interval: .nan, minimumDelay: 0) == 5_000)
        #expect([0, 1, 2, 3].map { MotionMapping.magneticAccuracy($0) } == [.uncalibrated, .low, .medium, .high])
        let derived = MotionMapping.quaternion([0, 0, 0.6])
        #expect(abs(derived.w - 0.8) < 1e-6)
        #expect(MotionMapping.quaternion([0.1, 0.2, 0.3, 0.9]).w == Double(Float(0.9)))
        #expect(MotionMapping.altitude(pressure: 1013.25, reference: 1013.25) == 0)
        #expect(abs(MotionMapping.altitude(pressure: 1001.3, reference: 1013.25) - 100) < 1, "about 12 Pa a meter near sea level")
        #expect(MotionMapping.authorization(.limited) == .authorized)
        #expect(MotionMapping.authorization(.unavailable) == .denied)
    }

    @Test func sharesSensorsAtTheFastestPeriod() {
        let first = AndroidMotionManager(delegate: RecordingMotion())
        var second: AndroidMotionManager? = AndroidMotionManager(delegate: RecordingMotion())
        first.start(MotionSensor.accelerometer.rawValue, interval: 0.1)
        second?.start(MotionSensor.accelerometer.rawValue, interval: 0.02)
        #expect(system.enabled[1] == 20_000)
        second = nil
        // The released manager's subscription goes when the sensor is next updated.
        first.start(MotionSensor.accelerometer.rawValue, interval: 0.1)
        #expect(system.enabled[1] == 100_000)
        first.stop(MotionSensor.accelerometer.rawValue)
        #expect(system.enabled[1] == nil)
        #expect(!first.isActive(MotionSensor.accelerometer.rawValue))
    }

    @Test func deliversSamples() {
        let delegate = RecordingMotion()
        let manager = AndroidMotionManager(delegate: delegate)
        manager.start(MotionSensor.accelerometer.rawValue, interval: 0.01)
        manager.start(MotionSensor.magnetometer.rawValue, interval: 0.01)
        hub.received(SensorSample(type: 1, timestamp: 5, values: [0, 0, 9.5]))
        hub.received(SensorSample(type: 2, timestamp: 6, values: [20, 0, -40], status: 1))
        hub.received(SensorSample(type: 4, timestamp: 7, values: [1, 2, 3]))
        #expect(delegate.events == ["acceleration 9.5 5", "magnetic 0"], "the gyroscope isn't started")
        #expect(AndroidMotionManager.isAvailable(MotionSensor.deviceMotion.rawValue))
        system.sensors.remove(15)
        #expect(!AndroidMotionManager.isAvailable(MotionSensor.deviceMotion.rawValue))
        manager.start(MotionSensor.deviceMotion.rawValue, interval: 0.01)
        #expect(delegate.events.last == "fail 3 \(MotionError.unavailable.rawValue)")
    }

    @Test func fusesDeviceMotion() throws {
        let delegate = RecordingMotion()
        let manager = AndroidMotionManager(delegate: delegate)
        manager.start(MotionSensor.deviceMotion.rawValue, interval: 0.01)
        #expect(Set(system.enabled.keys) == Set(SensorType.deviceMotion))
        hub.received(SensorSample(type: 9, timestamp: 1, values: [0, 0, 9.8]))
        hub.received(SensorSample(type: 10, timestamp: 1, values: [0.5, 0, 0]))
        hub.received(SensorSample(type: 4, timestamp: 1, values: [0, 0, 1]))
        hub.received(SensorSample(type: 15, timestamp: 2, values: [0, 0, 0, 1]))
        let motion = try #require(delegate.motions.first)
        #expect(motion.attitude == Quaternion(x: 0, y: 0, z: 0, w: 1))
        #expect(abs(motion.gravity.z - 9.8) < 1e-5)
        #expect(motion.userAcceleration.x == 0.5)
        #expect(motion.rotationRate.z == 1)
        #expect(motion.timestamp == 2)
        #expect(delegate.events.isEmpty, "the gyroscope feeds device motion without its own updates")
        // Stopping the gyroscope alone leaves device motion's.
        manager.start(MotionSensor.gyroscope.rawValue, interval: 0.01)
        manager.stop(MotionSensor.gyroscope.rawValue)
        #expect(system.enabled[4] != nil)
    }

    @Test func measuresAltitude() {
        let delegate = RecordingMotion()
        let altimeter = AndroidAltimeter(delegate: delegate)
        #expect(AndroidAltimeter.authorizationStatus() == MotionAuthorization.authorized.rawValue)
        altimeter.startUpdates()
        #expect(system.enabled[6] == 1_000_000)
        hub.received(SensorSample(type: 6, timestamp: 1, values: [1013.25]))
        hub.received(SensorSample(type: 6, timestamp: 2, values: [1001.3]))
        #expect(delegate.events == ["altitude 101.33 0.0", "altitude 100.13 100.0"])
        altimeter.stopUpdates()
        #expect(system.enabled[6] == nil)
    }

    @Test func countsSteps() {
        let delegate = RecordingMotion()
        let pedometer = AndroidPedometer(delegate: delegate)
        pedometer.startUpdates(from: 0)
        #expect(delegate.events == ["pedometer fail \(MotionError.unauthorized.rawValue)"])
        #expect(AndroidPedometer.authorizationStatus() == MotionAuthorization.notDetermined.rawValue)
        pedometer.requestAuthorization()
        #expect(permissions.requests == [["android.permission.ACTIVITY_RECOGNITION"]])
        permissions.granted = ["android.permission.ACTIVITY_RECOGNITION"]
        AndroidPermissions.didRequest(id: 1, permissions: [], granted: [])
        #expect(delegate.events.last == "pedometer authorization \(MotionAuthorization.authorized.rawValue)")
        pedometer.startUpdates(from: 0)
        hub.received(SensorSample(type: 19, timestamp: 1, values: [], steps: 5_000))
        hub.received(SensorSample(type: 19, timestamp: 2, values: [], steps: 5_012))
        #expect(delegate.events.suffix(2) == ["steps 0 true -1", "steps 12 true -1"])
        pedometer.query(from: 0, to: 1)
        #expect(delegate.events.last == "query \(MotionError.historyUnavailable.rawValue)")
        // Before API 29 there's no permission to ask for.
        permissions.apiLevel = 28
        permissions.granted = []
        #expect(AndroidPedometer.authorizationStatus() == MotionAuthorization.authorized.rawValue)
    }

    @Test func hasNoActivityRecognition() {
        let delegate = RecordingMotion()
        #expect(!AndroidActivityRecognizer.isAvailable())
        AndroidActivityRecognizer(delegate: delegate).startUpdates()
        #expect(delegate.events == ["activity fail \(MotionError.unavailable.rawValue)"])
    }

    @Test func registersEveryContract() {
        #expect(AndroidHostMotion.contracts.count == 8)
    }
}
