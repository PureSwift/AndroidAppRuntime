#if os(Android)
import AndroidHost
import CAndroidHost

/// The NDK's `ASensorManager`, with one event queue on the main thread's
/// `ALooper`: samples reach `MotionHub` on the main thread without JNI.
public final class NDKSensorSystem: SensorSystem {

    let manager: OpaquePointer

    private var queue: OpaquePointer?

    /// `ASensorManager_getInstanceForPackage` (API 26+). Main thread.
    public init?(package: String) {
        guard let manager = ASensorManager_getInstanceForPackage(package) else {
            return nil
        }
        self.manager = manager
    }

    deinit {
        if let queue {
            ASensorManager_destroyEventQueue(manager, queue)
        }
    }

    private func sensor(_ type: Int32) -> OpaquePointer? {
        ASensorManager_getDefaultSensor(manager, type)
    }

    public func hasSensor(_ type: Int32) -> Bool {
        sensor(type) != nil
    }

    public func minimumDelay(_ type: Int32) -> Int32 {
        sensor(type).map { ASensor_getMinDelay($0) } ?? 0
    }

    public func enable(_ type: Int32, period: Int32) -> Bool {
        guard let sensor = sensor(type), let queue = eventQueue() else { return false }
        return ASensorEventQueue_registerSensor(queue, sensor, period, 0) == 0
    }

    public func disable(_ type: Int32) {
        guard let sensor = sensor(type), let queue else { return }
        ASensorEventQueue_disableSensor(queue, sensor)
    }

    /// The queue, made on first use with the looper's callback.
    private func eventQueue() -> OpaquePointer? {
        if let queue {
            return queue
        }
        guard let looper = ALooper_forThread() else { return nil }
        queue = ASensorManager_createEventQueue(manager, looper, Int32(ALOOPER_POLL_CALLBACK), { _, _, data in
            guard let data else { return 0 }
            let system = Unmanaged<NDKSensorSystem>.fromOpaque(data).takeUnretainedValue()
            system.drain()
            return 1
        }, Unmanaged.passUnretained(self).toOpaque())
        return queue
    }

    /// Hands every waiting event to the hub.
    private func drain() {
        guard let queue else { return }
        var samples = [CAndroidSensorSample](repeating: CAndroidSensorSample(), count: 32)
        while true {
            let count = samples.withUnsafeMutableBufferPointer {
                candroid_sensor_read(queue, $0.baseAddress, Int32($0.count))
            }
            guard count > 0 else { return }
            for sample in samples.prefix(Int(count)) {
                let values = withUnsafeBytes(of: sample.values) { Array($0.bindMemory(to: Float.self).prefix(Int(sample.count))) }
                MotionHub.shared.received(SensorSample(type: sample.type, timestamp: sample.timestamp, values: values,
                                                       status: Int32(sample.status), steps: sample.steps))
            }
        }
    }
}
#endif
