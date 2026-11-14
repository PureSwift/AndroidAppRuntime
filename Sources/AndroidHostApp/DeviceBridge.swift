import AndroidHostDevice
import SwiftJava

/// The Kotlin `DeviceSystem` (`:appruntime-contracts`).
@JavaClass("org.pureswift.appruntime.contracts.DeviceSystem")
open class JavaDeviceSystem: JavaObject {

    @JavaMethod
    @_nonoverride public convenience init(environment: JNIEnvironment? = nil)

    @JavaMethod open func model() -> String
    @JavaMethod open func manufacturer() -> String
    @JavaMethod open func release() -> String
    @JavaMethod open func apiLevel() -> Int32
    @JavaMethod open func uiModeType() -> Int32
    @JavaMethod open func smallestWidthDp() -> Int32
    @JavaMethod open func isPC() -> Bool
    @JavaMethod open func fingerprint() -> String
    @JavaMethod open func hardware() -> String
    @JavaMethod open func product() -> String
    /// Empty if Android has no `ANDROID_ID`: swift-java returns no optional strings.
    @JavaMethod open func vendorIdentifier() -> String
    @JavaMethod open func physicalMemory() -> Int64
    @JavaMethod open func processorCount() -> Int32
    @JavaMethod open func name() -> String
    @JavaMethod open func battery() -> [Int32]
    @JavaMethod open func isPowerSaveMode() -> Bool
    @JavaMethod open func thermalStatus() -> Int32
    @JavaMethod open func hasProximitySensor() -> Bool
    @JavaMethod open func setListening(_ listener: Int32, _ on: Bool)
}

/// `AndroidHostDevice`'s system over the Kotlin class.
final class AndroidDeviceSystem: DeviceSystem {

    let java = JavaDeviceSystem()

    func facts() -> DeviceFacts {
        let vendor = java.vendorIdentifier()
        return DeviceFacts(
            model: java.model(), manufacturer: java.manufacturer(), release: java.release(),
            apiLevel: java.apiLevel(), uiModeType: java.uiModeType(), smallestWidthDP: java.smallestWidthDp(),
            isPC: java.isPC(), fingerprint: java.fingerprint(), hardware: java.hardware(), product: java.product(),
            vendorIdentifier: vendor.isEmpty ? nil : vendor, physicalMemory: java.physicalMemory(),
            processorCount: java.processorCount()
        )
    }

    func name() -> String {
        java.name()
    }

    func battery() -> AndroidBattery? {
        let values = java.battery()
        guard values.count == 5 else { return nil }
        return AndroidBattery(level: values[0], scale: values[1], status: values[2], plugged: values[3], present: values[4] == 1)
    }

    func isPowerSaveMode() -> Bool {
        java.isPowerSaveMode()
    }

    func thermalStatus() -> Int32 {
        java.thermalStatus()
    }

    func hasProximitySensor() -> Bool {
        java.hasProximitySensor()
    }

    func setListening(_ listener: DeviceListener, _ on: Bool) {
        java.setListening(listener.rawValue, on)
    }
}

/// The Kotlin `DeviceNatives` object: what `DeviceSystem`'s listeners hear.
@JavaClass("org.pureswift.appruntime.contracts.DeviceNatives")
open class DeviceNatives: JavaObject {}

@JavaImplementation("org.pureswift.appruntime.contracts.DeviceNatives")
extension DeviceNatives {

    @JavaMethod
    public func battery(_ level: Int32, _ scale: Int32, _ status: Int32, _ plugged: Int32, _ present: Bool) {
        DeviceHub.shared.batteryChanged(AndroidBattery(level: level, scale: scale, status: status, plugged: plugged, present: present))
    }

    @JavaMethod
    public func powerSaveMode(_ enabled: Bool) {
        DeviceHub.shared.powerSaveModeChanged(enabled)
    }

    @JavaMethod
    public func thermalStatus(_ status: Int32) {
        DeviceHub.shared.thermalStatusChanged(status)
    }

    @JavaMethod
    public func accelerometer(_ x: Float, _ y: Float, _ z: Float) {
        DeviceHub.shared.accelerometer(x: x, y: y, z: z)
    }

    @JavaMethod
    public func proximity(_ distance: Float, _ maximumRange: Float) {
        DeviceHub.shared.proximity(distance: distance, maximumRange: maximumRange)
    }
}
