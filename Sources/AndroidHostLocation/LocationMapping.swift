import AndroidHost
import DynamicLocation
import DynamicRuntime

/// Android's location permissions and providers to the contract's codes.
/// Pure, so tests check them on macOS.
enum LocationMapping {

    /// What the app holds of the three location permissions.
    struct Grants: Equatable {
        var fine = false
        var coarse = false
        var background = false
        /// Whether the app asked for foreground location before.
        var requested = false
        /// Whether the manifest declares the foreground permissions.
        var declared = true
    }

    static func grants(_ system: any PermissionSystem) -> Grants {
        Grants(
            fine: system.isGranted(AndroidPermissions.fineLocation),
            coarse: system.isGranted(AndroidPermissions.coarseLocation),
            background: system.isGranted(AndroidPermissions.backgroundLocation),
            requested: system.wasRequested(AndroidPermissions.fineLocation) || system.wasRequested(AndroidPermissions.coarseLocation),
            declared: system.isDeclared(AndroidPermissions.fineLocation) && system.isDeclared(AndroidPermissions.coarseLocation)
        )
    }

    /// Before API 29 foreground location also covers the background, so
    /// it's always.
    static func authorization(_ grants: Grants, api: Int32) -> LocationAuthorization {
        guard grants.declared else {
            return .denied
        }
        if grants.fine || grants.coarse {
            return api < 29 || grants.background ? .authorizedAlways : .authorizedWhenInUse
        }
        return grants.requested ? .denied : .notDetermined
    }

    /// Reduced when the user allowed approximate location only.
    static func accuracy(_ grants: Grants) -> LocationAccuracyAuthorization {
        grants.coarse && !grants.fine ? .reduced : .full
    }

    static func isAuthorized(_ status: LocationAuthorization) -> Bool {
        status == .authorizedAlways || status == .authorizedWhenInUse
    }

    // MARK: Requests

    /// `LocationRequest.QUALITY_*`.
    enum Quality {
        static let high: Int32 = 100
        static let balanced: Int32 = 102
        static let low: Int32 = 104
    }

    /// The contract's tiers (`LocationAccuracy`) as a quality and an
    /// interval in milliseconds.
    static func quality(_ accuracy: LocationAccuracy) -> (quality: Int32, interval: Int64) {
        switch accuracy {
        case .best, .nearestTenMeters: (Quality.high, 1_000)
        case .hundredMeters: (Quality.balanced, 5_000)
        case .kilometer: (Quality.low, 30_000)
        case .reduced: (Quality.low, 60_000)
        }
    }

    /// The fused provider when there is one (API 31+); otherwise GPS for
    /// high quality with fine location, and the network provider for the
    /// rest. GPS needs fine location. Nil if no provider fits.
    static func plan(_ accuracy: LocationAccuracy, distanceFilter: Double, providers: [String], fine: Bool) -> LocationPlan? {
        let (quality, interval) = quality(accuracy)
        let usable = providers.filter { $0 != "gps" || fine }
        let provider: String?
        if usable.contains("fused") {
            provider = "fused"
        } else if quality == Quality.high, usable.contains("gps") {
            provider = "gps"
        } else if usable.contains("network") {
            provider = "network"
        } else {
            provider = usable.first { $0 == "gps" }
        }
        return provider.map {
            LocationPlan(provider: $0, quality: quality, interval: interval, minimumDistance: max(0, distanceFilter))
        }
    }

    /// The newest of the last known fixes.
    static func newest(_ fixes: [LocationFixValues]) -> LocationFixValues? {
        fixes.max { $0.timestamp < $1.timestamp }
    }

    // MARK: Heading

    /// `SensorManager.SENSOR_STATUS_*` and the rotation vector's own
    /// estimate, in radians, to the contract's accuracy in degrees:
    /// negative when unreliable.
    static func headingAccuracy(status: Int32, estimate: Double) -> Double {
        switch status {
        case ...0: return -1
        default:
            if estimate > 0 {
                return estimate * 180 / .pi
            }
            return status >= 3 ? 10 : status == 2 ? 20 : 35
        }
    }

    /// Degrees in 0..<360.
    static func normalized(_ degrees: Double) -> Double {
        let remainder = degrees.truncatingRemainder(dividingBy: 360)
        return remainder < 0 ? remainder + 360 : remainder
    }

    /// The smallest angle between two headings.
    static func difference(_ a: Double, _ b: Double) -> Double {
        let difference = abs(normalized(a) - normalized(b))
        return min(difference, 360 - difference)
    }
}
