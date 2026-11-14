/// What `AndroidLocationManager` asks Android, through the Kotlin
/// `org.pureswift.appruntime.contracts.LocationSystem` (`AndroidHostApp`
/// binds it). Main thread only.
public protocol LocationSystem: AnyObject {

    /// `LocationManager.isLocationEnabled`.
    func isLocationEnabled() -> Bool

    /// The providers that are on: `fused` (API 31+), `gps`, `network`.
    func providers() -> [String]

    /// Whether there's a rotation vector sensor for the heading.
    func hasHeadingSensor() -> Bool

    /// `getLastKnownLocation` from each provider the app may use.
    func lastKnown() -> [LocationFixValues]

    /// `GeomagneticField`'s declination, in degrees, east positive.
    func declination(latitude: Double, longitude: Double, altitude: Double, time: Int64) -> Double

    /// A source for one manager; what it hears goes to
    /// `LocationHub.shared` with `handle`.
    func makeSource(handle: Int64) -> any LocationSource
}

/// One manager's listeners.
public protocol LocationSource: AnyObject {

    /// `requestLocationUpdates` on the main looper; false if Android
    /// refused (a permission is missing).
    func start(_ plan: LocationPlan) -> Bool

    func stop()

    /// The rotation vector sensor; false without one.
    func startHeading() -> Bool

    func stopHeading()
}

/// A `LocationRequest`: which provider, at what quality and how often.
public struct LocationPlan: Equatable, Sendable {

    /// `LocationManager.FUSED_PROVIDER`, `GPS_PROVIDER` or `NETWORK_PROVIDER`.
    public var provider: String

    /// `LocationRequest.QUALITY_*`.
    public var quality: Int32

    public var interval: Int64

    /// Meters; 0 for every change.
    public var minimumDistance: Double

    public init(provider: String, quality: Int32, interval: Int64, minimumDistance: Double) {
        self.provider = provider
        self.quality = quality
        self.interval = interval
        self.minimumDistance = minimumDistance
    }
}

/// An `android.location.Location`'s values, unavailable ones marked as the
/// contract marks them: negative, or `nan` for the altitude.
public struct LocationFixValues: Equatable, Sendable {

    public var latitude: Double
    public var longitude: Double
    public var altitude: Double
    public var horizontalAccuracy: Double
    public var verticalAccuracy: Double
    public var speed: Double
    public var speedAccuracy: Double
    public var course: Double
    public var courseAccuracy: Double
    /// Milliseconds since 1970.
    public var timestamp: Int64
    /// From a mock provider.
    public var isMock: Bool

    public init(latitude: Double, longitude: Double, altitude: Double = .nan, horizontalAccuracy: Double = -1,
                verticalAccuracy: Double = -1, speed: Double = -1, speedAccuracy: Double = -1, course: Double = -1,
                courseAccuracy: Double = -1, timestamp: Int64, isMock: Bool = false) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.speed = speed
        self.speedAccuracy = speedAccuracy
        self.course = course
        self.courseAccuracy = courseAccuracy
        self.timestamp = timestamp
        self.isMock = isMock
    }

    /// The Kotlin side's eleven doubles, in the order above.
    public init?(_ values: [Double]) {
        guard values.count == 11 else { return nil }
        self.init(latitude: values[0], longitude: values[1], altitude: values[2], horizontalAccuracy: values[3],
                  verticalAccuracy: values[4], speed: values[5], speedAccuracy: values[6], course: values[7],
                  courseAccuracy: values[8], timestamp: Int64(values[9]), isMock: values[10] != 0)
    }

    // Equatable with nan altitudes equal.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.latitude == rhs.latitude && lhs.longitude == rhs.longitude
            && (lhs.altitude == rhs.altitude || (lhs.altitude.isNaN && rhs.altitude.isNaN))
            && lhs.horizontalAccuracy == rhs.horizontalAccuracy && lhs.verticalAccuracy == rhs.verticalAccuracy
            && lhs.speed == rhs.speed && lhs.speedAccuracy == rhs.speedAccuracy && lhs.course == rhs.course
            && lhs.courseAccuracy == rhs.courseAccuracy && lhs.timestamp == rhs.timestamp && lhs.isMock == rhs.isMock
    }
}
