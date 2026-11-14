import AndroidHost
import DynamicLocation
import DynamicRuntime

/// The `Location` contract over an `android.location.Location`'s values.
public final class AndroidLocationFix: Location {

    public let values: LocationFixValues

    public init(_ values: LocationFixValues) {
        self.values = values
    }

    public func latitude() -> Double { values.latitude }

    public func longitude() -> Double { values.longitude }

    public func altitude() -> Double { values.altitude }

    public func horizontalAccuracy() -> Double { values.horizontalAccuracy }

    public func verticalAccuracy() -> Double { values.verticalAccuracy }

    public func speed() -> Double { values.speed }

    public func speedAccuracy() -> Double { values.speedAccuracy }

    public func course() -> Double { values.course }

    public func courseAccuracy() -> Double { values.courseAccuracy }

    public func timestamp() -> Int64 { values.timestamp }

    /// A mock provider's fix is simulated.
    public func isSimulated() -> Int32 { values.isMock ? 1 : 0 }
}

/// The `Heading` contract: the rotation vector's azimuth.
public final class AndroidHeading: Heading {

    let magnetic: Double

    let trueNorth: Double

    let accuracy: Double

    let time: Int64

    init(magneticHeading: Double, trueHeading: Double, headingAccuracy: Double, timestamp: Int64) {
        self.magnetic = magneticHeading
        self.trueNorth = trueHeading
        self.accuracy = headingAccuracy
        self.time = timestamp
    }

    public func magneticHeading() -> Double { magnetic }

    public func trueHeading() -> Double { trueNorth }

    public func headingAccuracy() -> Double { accuracy }

    public func timestamp() -> Int64 { time }
}

/// The Location contracts (`Plan.md` §6.2). `location`'s permission comes
/// from `AndroidPermissions`' table.
public enum AndroidHostLocation: HostModule {

    public static var contracts: [ContractDescriptor] {
        [LocationManagerProxy.descriptor, LocationManagerDelegateProxy.descriptor, LocationProxy.descriptor, HeadingProxy.descriptor]
    }

    public static func register(in registrar: some ContractRegistrar) {
        LocationManagerProxy.register(AndroidLocationManager.self, in: registrar)
        LocationManagerDelegateProxy.registerInterface(in: registrar)
        LocationProxy.register(AndroidLocationFix.self, in: registrar)
        HeadingProxy.register(AndroidHeading.self, in: registrar)
    }
}
