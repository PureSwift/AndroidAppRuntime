/// The NDK's sensors (`ASensorManager`, `Plan.md` §6.2), on the main
/// looper, with no JNI per sample. `NDKSensorSystem` is the real one;
/// tests use a fake. Main thread only.
public protocol SensorSystem: AnyObject {

    func hasSensor(_ type: Int32) -> Bool

    /// `ASensor_getMinDelay`, in microseconds; 0 for sensors that report on
    /// change.
    func minimumDelay(_ type: Int32) -> Int32

    /// Starts `type` every `period` microseconds; samples go to
    /// `MotionHub.shared.received`. False if Android refused.
    func enable(_ type: Int32, period: Int32) -> Bool

    func disable(_ type: Int32)
}

/// One `ASensorEvent`'s values.
public struct SensorSample: Equatable, Sendable {

    public var type: Int32

    /// Nanoseconds since boot (`CLOCK_BOOTTIME`), as Android stamps them.
    public var timestamp: Int64

    /// Up to five values, as the sensor type defines them.
    public var values: [Float]

    /// `SENSOR_STATUS_*`: 0 unreliable to 3 high.
    public var status: Int32

    /// `TYPE_STEP_COUNTER`'s count since boot.
    public var steps: UInt64

    public init(type: Int32, timestamp: Int64, values: [Float], status: Int32 = 3, steps: UInt64 = 0) {
        self.type = type
        self.timestamp = timestamp
        self.values = values
        self.status = status
        self.steps = steps
    }
}

/// `ASENSOR_TYPE_*`.
public enum SensorType {
    public static let accelerometer: Int32 = 1
    public static let magneticField: Int32 = 2
    public static let gyroscope: Int32 = 4
    public static let pressure: Int32 = 6
    public static let gravity: Int32 = 9
    public static let linearAcceleration: Int32 = 10
    public static let gameRotationVector: Int32 = 15
    public static let stepCounter: Int32 = 19

    /// What fused device motion reads.
    public static let deviceMotion = [gameRotationVector, gravity, linearAcceleration, gyroscope]
}
