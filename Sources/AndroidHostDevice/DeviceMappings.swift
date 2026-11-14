import DynamicDevice

/// Android's values to the `Device` contract's codes. Pure, so tests check
/// them on macOS.
enum DeviceMappings {

    // MARK: Identity

    /// `Build.MANUFACTURER` with its first letter capitalized: some are
    /// lowercase ("samsung").
    static func manufacturer(_ value: String) -> String {
        guard let first = value.first else { return value }
        return first.uppercased() + value.dropFirst()
    }

    /// `Configuration.UI_MODE_TYPE_*`.
    enum UIModeType {
        static let desk: Int32 = 2
        static let car: Int32 = 3
        static let television: Int32 = 4
        static let watch: Int32 = 6
        static let vrHeadset: Int32 = 7
    }

    /// The UI mode type first, then a PC, then the screen: 600 dp and wider
    /// is a tablet, as Android's own resource qualifiers have it.
    static func idiom(_ facts: DeviceFacts) -> DeviceIdiom {
        switch facts.uiModeType {
        case UIModeType.television: return .tv
        case UIModeType.car: return .car
        case UIModeType.watch: return .watch
        case UIModeType.vrHeadset: return .vision
        case UIModeType.desk: return .desktop
        default: break
        }
        if facts.isPC {
            return .desktop
        }
        return facts.smallestWidthDP >= 600 ? .pad : .phone
    }

    /// The emulator's builds: `ranchu` and `goldfish` hardware, and
    /// `sdk_gphone…` and `generic` fingerprints and products.
    static func isEmulator(_ facts: DeviceFacts) -> Bool {
        let hardware = facts.hardware.lowercased()
        let fingerprint = facts.fingerprint.lowercased()
        let product = facts.product.lowercased()
        return hardware == "ranchu" || hardware == "goldfish"
            || fingerprint.hasPrefix("generic") || fingerprint.contains("emulator")
            || product.hasPrefix("sdk") || product.contains("_sdk") || product.contains("emulator")
    }

    // MARK: Power

    /// `BatteryManager.BATTERY_STATUS_*`.
    enum BatteryStatus {
        static let full: Int32 = 5
    }

    /// The level as 0–1, and the state. Plugged in, the battery is full once
    /// Android says so or it reaches 100%, and charging otherwise, also
    /// while Android holds the charge, as a plugged-in iPhone reports.
    static func battery(_ battery: AndroidBattery?) -> BatteryReading {
        guard let battery, battery.present else {
            return .none
        }
        var level: Float = -1
        if battery.scale > 0, battery.level >= 0 {
            level = min(1, Float(battery.level) / Float(battery.scale))
        }
        let state: BatteryState
        if battery.plugged == 0 {
            state = .unplugged
        } else if battery.status == BatteryStatus.full || level >= 1 {
            state = .full
        } else {
            state = .charging
        }
        return BatteryReading(level: level, state: state)
    }

    /// `PowerManager.THERMAL_STATUS_*` (`DeviceTypes`): none and light are
    /// nominal, moderate fair, severe serious, and critical and above
    /// critical.
    static func thermalState(_ status: Int32) -> ThermalState {
        switch status {
        case ...1: .nominal
        case 2: .fair
        case 3: .serious
        default: .critical
        }
    }

    // MARK: Orientation and proximity

    /// The physical orientation from the accelerometer, in m/s² on the
    /// device's axes (x right, y up, z out of the screen). Gravity reads
    /// as +9.8 on the axis pointing up.
    ///
    /// Flat is face up or down; otherwise the larger of x and y decides.
    /// Near a diagonal, or in free fall, the last orientation stays, so it
    /// doesn't flicker.
    static func orientation(x: Float, y: Float, z: Float, last: DeviceOrientation) -> DeviceOrientation {
        let magnitude = (x * x + y * y + z * z).squareRoot()
        guard magnitude > 2 else {
            return last
        }
        if abs(z) > magnitude * 0.85 {
            return z > 0 ? .faceUp : .faceDown
        }
        let (ax, ay) = (abs(x), abs(y))
        if ay > ax * 1.3 {
            return y > 0 ? .portrait : .portraitUpsideDown
        }
        if ax > ay * 1.3 {
            // The right side up means the top is to the left.
            return x > 0 ? .landscapeLeft : .landscapeRight
        }
        return last
    }

    /// Near when the distance is under the sensor's range, capped at 5 cm:
    /// most sensors report only 0 or their maximum.
    static func isNear(distance: Float, maximumRange: Float) -> Bool {
        distance < min(maximumRange, 5)
    }
}

/// The battery's level (0–1, or `-1`) and state.
struct BatteryReading: Equatable {

    var level: Float

    var state: BatteryState

    /// No battery, or monitoring is off.
    static let none = BatteryReading(level: -1, state: .unknown)
}
