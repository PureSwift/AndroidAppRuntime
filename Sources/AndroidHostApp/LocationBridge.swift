import AndroidHostLocation
import SwiftJava

/// The Kotlin `LocationSystem` (`:appruntime-contracts`).
@JavaClass("org.pureswift.appruntime.contracts.LocationSystem")
open class JavaLocationSystem: JavaObject {

    @JavaMethod
    @_nonoverride public convenience init(environment: JNIEnvironment? = nil)

    @JavaMethod open func isLocationEnabled() -> Bool
    @JavaMethod open func providers() -> [String]
    @JavaMethod open func hasHeadingSensor() -> Bool
    @JavaMethod open func lastKnown() -> [Double]
    @JavaMethod open func declination(_ latitude: Double, _ longitude: Double, _ altitude: Double, _ time: Int64) -> Double
    @JavaMethod open func makeSource(_ handle: Int64) -> JavaLocationSource!
}

@JavaClass("org.pureswift.appruntime.contracts.LocationSource")
open class JavaLocationSource: JavaObject {
    @JavaMethod open func start(_ provider: String, _ quality: Int32, _ interval: Int64, _ minimumDistance: Double) -> Bool
    @JavaMethod open func stop()
    @JavaMethod open func startHeading() -> Bool
    @JavaMethod open func stopHeading()
}

/// `AndroidHostLocation`'s system over the Kotlin class.
final class AndroidLocationSystem: LocationSystem {

    let java = JavaLocationSystem()

    func isLocationEnabled() -> Bool {
        java.isLocationEnabled()
    }

    func providers() -> [String] {
        java.providers()
    }

    func hasHeadingSensor() -> Bool {
        java.hasHeadingSensor()
    }

    func lastKnown() -> [LocationFixValues] {
        let values = java.lastKnown()
        return stride(from: 0, to: values.count - values.count % 11, by: 11).compactMap {
            LocationFixValues(Array(values[$0..<$0 + 11]))
        }
    }

    func declination(latitude: Double, longitude: Double, altitude: Double, time: Int64) -> Double {
        java.declination(latitude, longitude, altitude, time)
    }

    func makeSource(handle: Int64) -> any LocationSource {
        SourceAdapter(java.makeSource(handle))
    }

    final class SourceAdapter: LocationSource {

        let java: JavaLocationSource

        init(_ java: JavaLocationSource) {
            self.java = java
        }

        func start(_ plan: LocationPlan) -> Bool {
            java.start(plan.provider, plan.quality, plan.interval, plan.minimumDistance)
        }

        func stop() {
            java.stop()
        }

        func startHeading() -> Bool {
            java.startHeading()
        }

        func stopHeading() {
            java.stopHeading()
        }
    }
}

/// The Kotlin `LocationNatives` object: what each `LocationSource` hears.
@JavaClass("org.pureswift.appruntime.contracts.LocationNatives")
open class LocationNatives: JavaObject {}

@JavaImplementation("org.pureswift.appruntime.contracts.LocationNatives")
extension LocationNatives {

    @JavaMethod
    public func location(_ handle: Int64, _ values: [Double]) {
        LocationHub.shared.location(handle: handle, values)
    }

    @JavaMethod
    public func providerDisabled(_ handle: Int64) {
        LocationHub.shared.providerDisabled(handle: handle)
    }

    @JavaMethod
    public func heading(_ handle: Int64, _ azimuth: Double, _ status: Int32, _ estimate: Double, _ timestamp: Int64) {
        LocationHub.shared.heading(handle: handle, azimuth: azimuth, status: status, estimate: estimate, timestamp: timestamp)
    }
}
