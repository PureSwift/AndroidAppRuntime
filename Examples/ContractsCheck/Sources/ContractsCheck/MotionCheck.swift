import DynamicMotion
import DynamicRuntime

/// `MotionManager`, `Altimeter` and `Pedometer`: the first sample of each
/// sensor the device has, and the activity recognition prompt (the script
/// taps "Allow").
final class MotionCheck: MotionManagerDelegate, AltimeterDelegate, PedometerDelegate {

    let report: Report

    var manager: MotionManager?

    var altimeter: Altimeter?

    var pedometer: Pedometer?

    private var sawAcceleration = false

    private var sawDeviceMotion = false

    init(report: Report) {
        self.report = report
    }

    func run() {
        report.check(MotionManagerProxy.isAvailable(MotionSensor.accelerometer.rawValue), "motion.isAvailable accelerometer")
        let fused = MotionManagerProxy.isAvailable(MotionSensor.deviceMotion.rawValue)
        report.note("motion.isAvailable deviceMotion \(fused)")
        let manager = MotionManagerProxy.make(self)
        self.manager = manager
        manager.start(MotionSensor.accelerometer.rawValue, interval: 0.05)
        if fused {
            manager.start(MotionSensor.deviceMotion.rawValue, interval: 0.05)
        }
        if AltimeterProxy.isAvailable() {
            altimeter = AltimeterProxy.make(self)
            altimeter?.startUpdates()
        } else {
            report.note("motion.altimeter unavailable")
        }
        report.note("motion.isStepCountingAvailable \(PedometerProxy.isStepCountingAvailable())")
        let status = PedometerProxy.authorizationStatus()
        report.check(status == MotionAuthorization.notDetermined.rawValue, "motion.pedometer authorizationStatus \(status)")
        let pedometer = PedometerProxy.make(self)
        self.pedometer = pedometer
        report.note("motion.requesting")
        pedometer.requestAuthorization()
    }

    // MotionManager

    func didUpdateAcceleration(_ manager: MotionManager, x: Double, y: Double, z: Double, timestamp: Int64) {
        guard !sawAcceleration else { return }
        sawAcceleration = true
        let magnitude = Vector3(x: x, y: y, z: z).magnitude
        report.check(magnitude > 8 && magnitude < 12 && timestamp > 0, "motion.didUpdateAcceleration \(Int(magnitude * 10))")
        manager.stop(MotionSensor.accelerometer.rawValue)
    }

    func didUpdateRotationRate(_ manager: MotionManager, x: Double, y: Double, z: Double, timestamp: Int64) {}

    func didUpdateMagneticField(_ manager: MotionManager, x: Double, y: Double, z: Double, accuracy: Int32, timestamp: Int64) {}

    func didUpdateDeviceMotion(_ manager: MotionManager, attitudeX: Double, attitudeY: Double, attitudeZ: Double, attitudeW: Double,
                               gravityX: Double, gravityY: Double, gravityZ: Double, userAccelerationX: Double, userAccelerationY: Double,
                               userAccelerationZ: Double, rotationRateX: Double, rotationRateY: Double, rotationRateZ: Double, timestamp: Int64) {
        guard !sawDeviceMotion else { return }
        let attitude = Quaternion(x: attitudeX, y: attitudeY, z: attitudeZ, w: attitudeW)
        let length = (attitude.x * attitude.x + attitude.y * attitude.y + attitude.z * attitude.z + attitude.w * attitude.w).squareRoot()
        let gravity = Vector3(x: gravityX, y: gravityY, z: gravityZ).magnitude
        // The first samples can come before gravity's.
        guard gravity > 1 else { return }
        sawDeviceMotion = true
        report.check(abs(length - 1) < 0.01 && gravity > 8 && gravity < 12, "motion.didUpdateDeviceMotion \(Int(gravity * 10))")
        manager.stop(MotionSensor.deviceMotion.rawValue)
    }

    func didFail(_ manager: MotionManager, sensor: Int32, error: Int32) {
        report.check(false, "motion.didFail \(sensor) \(error)")
    }

    // Altimeter

    func didChangeAuthorization(_ altimeter: Altimeter, status: Int32) {}

    func didUpdate(_ altimeter: Altimeter, pressure: Double, relativeAltitude: Double, timestamp: Int64) {
        report.check(pressure > 50 && pressure < 120 && relativeAltitude == 0, "motion.altimeter \(Int(pressure)) kPa")
        altimeter.stopUpdates()
    }

    func didFail(_ altimeter: Altimeter, error: Int32) {
        report.check(false, "motion.altimeter didFail \(error)")
    }

    // Pedometer

    func didChangeAuthorization(_ pedometer: Pedometer, status: Int32) {
        report.check(status == MotionAuthorization.authorized.rawValue, "motion.pedometer didChangeAuthorization \(status)")
        Checks.startNFC()
    }

    func didUpdate(_ pedometer: Pedometer, steps: Int64, distance: Double, floorsAscended: Int32, floorsDescended: Int32, start: Int64, end: Int64) {}

    func didQuery(_ pedometer: Pedometer, steps: Int64, distance: Double, floorsAscended: Int32, floorsDescended: Int32, start: Int64, end: Int64, error: Int32) {}

    func didFail(_ pedometer: Pedometer, error: Int32) {
        report.note("motion.pedometer didFail \(error)")
    }
}
