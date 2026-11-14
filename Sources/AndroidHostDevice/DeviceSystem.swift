/// What `AndroidDevice` reads from Android, through the Kotlin
/// `org.pureswift.appruntime.contracts.DeviceSystem` (`AndroidHostApp`
/// binds it). Raw Android values: `DeviceMappings` turns them into the
/// contract's codes. Main thread only.
public protocol DeviceSystem: AnyObject {

    /// What doesn't change while the process runs.
    func facts() -> DeviceFacts

    /// `Settings.Global.DEVICE_NAME`, or `Build.MODEL`.
    func name() -> String

    /// The sticky `ACTION_BATTERY_CHANGED` broadcast; nil if there's none.
    func battery() -> AndroidBattery?

    /// `PowerManager.isPowerSaveMode`.
    func isPowerSaveMode() -> Bool

    /// `PowerManager.getCurrentThermalStatus`.
    func thermalStatus() -> Int32

    /// Whether there's a `TYPE_PROXIMITY` sensor.
    func hasProximitySensor() -> Bool

    /// Turns the system's listener on or off. What it hears goes to
    /// `DeviceHub.shared`, on the main thread.
    func setListening(_ listener: DeviceListener, _ on: Bool)
}

/// The system's listeners behind `Device`'s updates.
public enum DeviceListener: Int32, CaseIterable, Sendable {
    /// `ACTION_POWER_SAVE_MODE_CHANGED` and the thermal status listener.
    case power = 0
    /// `ACTION_BATTERY_CHANGED`.
    case battery = 1
    /// The accelerometer, for the physical orientation.
    case orientation = 2
    /// `TYPE_PROXIMITY`.
    case proximity = 3
}

/// The device's fixed facts, read once.
public struct DeviceFacts: Equatable, Sendable {

    /// `Build.MODEL`, such as "Pixel 8" or "SM-S918B".
    public var model: String

    /// `Build.MANUFACTURER`, such as "Google" or "samsung".
    public var manufacturer: String

    /// `Build.VERSION.RELEASE`, such as "14".
    public var release: String

    /// `Build.VERSION.SDK_INT`.
    public var apiLevel: Int32

    /// `Configuration.uiMode & UI_MODE_TYPE_MASK`.
    public var uiModeType: Int32

    /// `Configuration.smallestScreenWidthDp`.
    public var smallestWidthDP: Int32

    /// `PackageManager.FEATURE_PC`: a Chromebook or a desktop.
    public var isPC: Bool

    /// `Build.FINGERPRINT`, `Build.HARDWARE` and `Build.PRODUCT`, which tell
    /// an emulator.
    public var fingerprint: String

    public var hardware: String

    public var product: String

    /// A UUID made from `Settings.Secure.ANDROID_ID`, which is per signing
    /// key, user and device; nil if Android has none.
    public var vendorIdentifier: String?

    /// `ActivityManager.MemoryInfo.totalMem`.
    public var physicalMemory: Int64

    /// `Runtime.availableProcessors()`.
    public var processorCount: Int32

    public init(model: String, manufacturer: String, release: String, apiLevel: Int32, uiModeType: Int32,
                smallestWidthDP: Int32, isPC: Bool, fingerprint: String, hardware: String, product: String,
                vendorIdentifier: String?, physicalMemory: Int64, processorCount: Int32) {
        self.model = model
        self.manufacturer = manufacturer
        self.release = release
        self.apiLevel = apiLevel
        self.uiModeType = uiModeType
        self.smallestWidthDP = smallestWidthDP
        self.isPC = isPC
        self.fingerprint = fingerprint
        self.hardware = hardware
        self.product = product
        self.vendorIdentifier = vendorIdentifier
        self.physicalMemory = physicalMemory
        self.processorCount = processorCount
    }
}

/// `ACTION_BATTERY_CHANGED`'s extras.
public struct AndroidBattery: Equatable, Sendable {

    /// `EXTRA_LEVEL`, out of `scale`.
    public var level: Int32

    /// `EXTRA_SCALE`.
    public var scale: Int32

    /// `EXTRA_STATUS`: a `BATTERY_STATUS_*` value.
    public var status: Int32

    /// `EXTRA_PLUGGED`: 0 on battery, otherwise a `BATTERY_PLUGGED_*` value.
    public var plugged: Int32

    /// `EXTRA_PRESENT`.
    public var present: Bool

    public init(level: Int32, scale: Int32, status: Int32, plugged: Int32, present: Bool) {
        self.level = level
        self.scale = scale
        self.status = status
        self.plugged = plugged
        self.present = present
    }
}
