import DynamicMotion
import DynamicRuntime
#if canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Android's sensor values to the Motion contracts'. Pure, so tests check
/// them on macOS.
enum MotionMapping {

    /// The NDK sensors behind a `MotionSensor`: device motion fuses four.
    static func sensorTypes(_ sensor: MotionSensor) -> [Int32] {
        switch sensor {
        case .accelerometer: [SensorType.accelerometer]
        case .gyroscope: [SensorType.gyroscope]
        case .magnetometer: [SensorType.magneticField]
        case .deviceMotion: SensorType.deviceMotion
        }
    }

    /// The period in microseconds for an interval in seconds, no shorter
    /// than the sensor allows; 200 Hz at most, Android 12's limit without
    /// `HIGH_SAMPLING_RATE_SENSORS`.
    static func period(interval: Double, minimumDelay: Int32) -> Int32 {
        let requested = interval.isFinite && interval > 0 ? interval * 1_000_000 : 0
        let floor = max(Double(minimumDelay), 5_000)
        return Int32(min(max(requested, floor), Double(Int32.max)))
    }

    /// `SENSOR_STATUS_*` to a `MagneticFieldAccuracy`.
    static func magneticAccuracy(_ status: Int32) -> MagneticFieldAccuracy {
        switch status {
        case ...0: .uncalibrated
        case 1: .low
        case 2: .medium
        default: .high
        }
    }

    /// A rotation vector's unit quaternion (x, y, z, w): the fourth value
    /// when the sensor sends it, otherwise derived.
    static func quaternion(_ values: [Float]) -> Quaternion {
        let x = Double(values.count > 0 ? values[0] : 0)
        let y = Double(values.count > 1 ? values[1] : 0)
        let z = Double(values.count > 2 ? values[2] : 0)
        let w = values.count > 3 ? Double(values[3]) : max(0, 1 - x * x - y * y - z * z).squareRoot()
        return Quaternion(x: x, y: y, z: z, w: w)
    }

    /// `SensorManager.getAltitude`: meters above the pressure `reference`,
    /// both in hPa, from the international barometric formula.
    static func altitude(pressure: Double, reference: Double) -> Double {
        44_330 * (1 - pow(pressure / reference, 1 / 5.255))
    }

    /// The `motion` capability's permission status as a
    /// `MotionAuthorization`.
    static func authorization(_ status: PermissionStatus) -> MotionAuthorization {
        switch status {
        case .granted, .limited: .authorized
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied, .unavailable: .denied
        }
    }

    /// Milliseconds since 1970, for the pedometer's dates.
    static func now() -> Int64 {
        var time = timespec()
        clock_gettime(CLOCK_REALTIME, &time)
        return Int64(time.tv_sec) * 1000 + Int64(time.tv_nsec) / 1_000_000
    }
}
