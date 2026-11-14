import AndroidHost
import AndroidHostMotion

/// The NDK's sensors for `AndroidHostMotion`, for the app's package.
enum MotionSensors {

    static func make() -> any SensorSystem {
        #if os(Android)
        if let system = NDKSensorSystem(package: AndroidBundle.info.identifier) {
            return system
        }
        #endif
        return None()
    }

    /// No sensors: off Android, or if the NDK has no sensor manager.
    final class None: SensorSystem {
        func hasSensor(_ type: Int32) -> Bool { false }
        func minimumDelay(_ type: Int32) -> Int32 { 0 }
        func enable(_ type: Int32, period: Int32) -> Bool { false }
        func disable(_ type: Int32) {}
    }
}
