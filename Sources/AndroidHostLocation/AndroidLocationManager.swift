import AndroidHost
import DynamicLocation
import DynamicRuntime

/// The `LocationManager` contract over `android.location.LocationManager`
/// (`Plan.md` §6.2), without Google Play services, so apps work on any
/// device.
///
/// - **Authorization** comes from the three location permissions
///   (`LocationMapping`). Requests go through `AndroidPermissions`; every
///   manager hears the outcome, and the change the user makes in Settings
///   when the app comes back.
/// - **Updates** use the fused provider when there is one (API 31+),
///   otherwise GPS and network, on the main looper.
/// - **Heading** is the rotation vector sensor's azimuth; true north once a
///   location is known.
/// - **Background updates** run in the host's foreground service
///   (`HostBackground`), with a notification, while updates run with
///   background updates on and `authorizedAlways`; without it Android
///   throttles them in the background.
public final class AndroidLocationManager: LocationManager {

    let hub: LocationHub

    let handle: Int64

    /// Kept strongly (`Plan.md` §6).
    let delegate: any LocationManagerDelegate

    private(set) var desiredAccuracy = LocationAccuracy.best

    private(set) var distanceFilter: Double = 0

    private(set) var backgroundUpdates = false

    /// Whether the guest asked for continuous updates.
    private(set) var updating = false

    /// Whether a one-shot request is waiting for its fix.
    private(set) var requestingOnce = false

    private(set) var updatingHeading = false

    /// The plan the source runs, if it runs.
    private(set) var running: LocationPlan?

    private var timeout: TimerQueue.Token?

    /// What the delegate last heard.
    private var lastAuthorization: (LocationAuthorization, LocationAccuracyAuthorization)?

    private var lastHeading: Double?

    lazy var source: any LocationSource = hub.system.makeSource(handle: handle)

    /// How long `requestLocation` waits for a fix before failing with
    /// `locationUnknown`, in nanoseconds.
    nonisolated(unsafe) static var requestTimeout: Int64 = 30_000_000_000

    init(delegate: any LocationManagerDelegate, hub: LocationHub = .shared) {
        self.delegate = delegate
        self.hub = hub
        self.handle = hub.add()
        hub.managers[handle] = WeakManager(manager: self)
    }

    deinit {
        HostBackground.set(.location, false, for: self)
        if running != nil {
            source.stop()
        }
        if updatingHeading {
            source.stopHeading()
        }
        if let timeout {
            MainLooper.shared.cancel(timeout)
        }
        hub.managers[handle] = nil
    }

    // MARK: Statics

    public static func authorizationStatus() -> Int32 {
        LocationHub.shared.authorization.0.rawValue
    }

    public static func accuracyAuthorization() -> Int32 {
        LocationHub.shared.authorization.1.rawValue
    }

    public static func isLocationServicesEnabled() -> Bool {
        LocationHub.shared.system.isLocationEnabled()
    }

    public static func isHeadingAvailable() -> Bool {
        LocationHub.shared.system.hasHeadingSensor()
    }

    /// Sends the current authorization once, as `CLLocationManager` does.
    public static func make(_ delegate: any LocationManagerDelegate) -> AndroidLocationManager {
        let manager = AndroidLocationManager(delegate: delegate)
        MainLooper.shared.post { [weak manager] in
            manager?.reportAuthorization()
        }
        return manager
    }

    // MARK: Authorization

    public func requestWhenInUseAuthorization() {
        let (status, _) = hub.authorization
        guard status == .notDetermined || status == .denied else {
            reportAuthorization()
            return
        }
        hub.request([AndroidPermissions.fineLocation, AndroidPermissions.coarseLocation])
    }

    /// Valid once when-in-use is granted. API 29 asks; on API 30+ Android
    /// opens the app's location settings, and the answer comes back when
    /// the user returns.
    public func requestAlwaysAuthorization() {
        let (status, _) = hub.authorization
        guard status == .authorizedWhenInUse else {
            reportAuthorization()
            return
        }
        guard hub.permissions?.isDeclared(AndroidPermissions.backgroundLocation) == true else {
            HostLog.error("LocationManager.requestAlwaysAuthorization: the manifest doesn't declare ACCESS_BACKGROUND_LOCATION; declare location(.always)")
            delegate.didFail(self, error: LocationError.denied.rawValue)
            return
        }
        hub.request([AndroidPermissions.backgroundLocation])
    }

    /// Asks for fine location again: Android 12+ offers to upgrade an
    /// approximate grant.
    public func requestFullAccuracy(_ purpose: String) {
        let (status, accuracy) = hub.authorization
        guard LocationMapping.isAuthorized(status), accuracy == .reduced else {
            reportAuthorization()
            return
        }
        hub.request([AndroidPermissions.fineLocation, AndroidPermissions.coarseLocation])
    }

    /// Tells the delegate the authorization if it changed since it last
    /// heard; restarts or stops updates to match.
    func reportAuthorization() {
        let current = hub.authorization
        if let last = lastAuthorization, last == current {
            return
        }
        lastAuthorization = current
        delegate.didChangeAuthorization(self, status: current.0.rawValue, accuracy: current.1.rawValue)
        if running != nil || updating || requestingOnce {
            restart()
        }
    }

    // MARK: Settings

    public func setDesiredAccuracy(_ accuracy: Int32) {
        guard let accuracy = LocationAccuracy(rawValue: accuracy) else {
            HostLog.error("LocationManager.setDesiredAccuracy: unknown accuracy \(accuracy)")
            return
        }
        desiredAccuracy = accuracy
        if running != nil {
            restart()
        }
    }

    public func setDistanceFilter(_ meters: Double) {
        distanceFilter = meters.isFinite ? max(0, meters) : 0
        if running != nil {
            restart()
        }
    }

    public func setBackgroundUpdatesEnabled(_ enabled: Bool) {
        backgroundUpdates = enabled
        if enabled, hub.authorization.0 != .authorizedAlways {
            delegate.didFail(self, error: LocationError.backgroundNotAllowed.rawValue)
        }
        updateBackgroundWork()
    }

    /// The foreground service runs while this manager updates in the
    /// background with authorization to.
    func updateBackgroundWork() {
        let wanted = backgroundUpdates && running != nil && hub.authorization.0 == .authorizedAlways
        HostBackground.set(.location, wanted, for: self)
    }

    // MARK: Updates

    public func startUpdatingLocation() {
        updating = true
        restart()
    }

    public func stopUpdatingLocation() {
        updating = false
        if !requestingOnce {
            stopSource()
        }
    }

    public func requestLocation() {
        requestingOnce = true
        if let timeout {
            MainLooper.shared.cancel(timeout)
        }
        timeout = MainLooper.shared.schedule(after: Self.requestTimeout) { [weak self] in
            self?.requestTimedOut()
        }
        restart()
    }

    public func lastLocation() -> (any Location)? {
        guard LocationMapping.isAuthorized(hub.authorization.0) else { return nil }
        return LocationMapping.newest(hub.system.lastKnown()).map(AndroidLocationFix.init)
    }

    /// Starts the source for what's wanted, or fails as CoreLocation does:
    /// denied without authorization, services disabled when they're off.
    func restart() {
        guard updating || requestingOnce else {
            stopSource()
            return
        }
        let (status, accuracy) = hub.authorization
        guard LocationMapping.isAuthorized(status) else {
            stop(failing: .denied)
            return
        }
        let system = hub.system
        guard system.isLocationEnabled(),
              let plan = LocationMapping.plan(desiredAccuracy, distanceFilter: distanceFilter,
                                              providers: system.providers(), fine: accuracy == .full) else {
            stop(failing: .servicesDisabled)
            return
        }
        guard plan != running else { return }
        if running != nil {
            source.stop()
        }
        if source.start(plan) {
            running = plan
            updateBackgroundWork()
        } else {
            running = nil
            stop(failing: .denied)
        }
    }

    private func stopSource() {
        if running != nil {
            source.stop()
            running = nil
        }
        updateBackgroundWork()
    }

    /// Stops updates and the one-shot request, and tells the delegate.
    private func stop(failing error: LocationError) {
        stopSource()
        updating = false
        finishOnce()
        delegate.didFail(self, error: error.rawValue)
    }

    private func finishOnce() {
        requestingOnce = false
        if let timeout {
            MainLooper.shared.cancel(timeout)
            self.timeout = nil
        }
    }

    private func requestTimedOut() {
        timeout = nil
        guard requestingOnce else { return }
        requestingOnce = false
        if !updating {
            stopSource()
        }
        delegate.didFail(self, error: LocationError.locationUnknown.rawValue)
    }

    /// A fix from the source.
    func received(_ fix: LocationFixValues) {
        hub.lastFix = fix
        guard updating || requestingOnce else { return }
        if requestingOnce {
            finishOnce()
            if !updating {
                stopSource()
            }
        }
        delegate.didUpdateLocations(self, locations: [AndroidLocationFix(fix)])
    }

    /// The provider was turned off while updating.
    func providerDisabled() {
        guard running != nil else { return }
        stop(failing: .servicesDisabled)
    }

    // MARK: Heading

    public func startUpdatingHeading() {
        guard !updatingHeading else { return }
        guard source.startHeading() else {
            delegate.didFail(self, error: LocationError.headingFailure.rawValue)
            return
        }
        updatingHeading = true
        lastHeading = nil
    }

    public func stopUpdatingHeading() {
        guard updatingHeading else { return }
        updatingHeading = false
        source.stopHeading()
    }

    /// A rotation vector reading: changes under a degree aren't reported,
    /// like CoreLocation's default heading filter.
    func received(azimuth: Double, status: Int32, estimate: Double, timestamp: Int64) {
        guard updatingHeading else { return }
        let magnetic = LocationMapping.normalized(azimuth)
        if let lastHeading, LocationMapping.difference(lastHeading, magnetic) < 1 {
            return
        }
        lastHeading = magnetic
        var trueHeading = -1.0
        if let fix = hub.lastFix {
            let declination = hub.system.declination(latitude: fix.latitude, longitude: fix.longitude,
                                                     altitude: fix.altitude.isNaN ? 0 : fix.altitude, time: timestamp)
            trueHeading = LocationMapping.normalized(magnetic + declination)
        }
        let heading = AndroidHeading(magneticHeading: magnetic, trueHeading: trueHeading,
                                     headingAccuracy: LocationMapping.headingAccuracy(status: status, estimate: estimate),
                                     timestamp: timestamp)
        delegate.didUpdateHeading(self, heading: heading)
    }
}

/// Every `AndroidLocationManager`, by handle, and what they share. Main
/// thread only.
public final class LocationHub {

    nonisolated(unsafe) public static let shared = LocationHub()

    /// Makes the system on first use; `AndroidHostApp` sets it.
    public var makeSystem: (() -> any LocationSystem)?

    private var _system: (any LocationSystem)?

    public var system: any LocationSystem {
        if let _system {
            return _system
        }
        guard let makeSystem else {
            fatalError("LocationHub.makeSystem isn't set")
        }
        let system = makeSystem()
        _system = system
        return system
    }

    /// The runtime permissions; `AndroidPermissions.system` unless a test
    /// sets one.
    public var permissions: (any PermissionSystem)? {
        get { _permissions ?? AndroidPermissions.system }
        set { _permissions = newValue }
    }

    private var _permissions: (any PermissionSystem)?

    fileprivate var managers: [Int64: WeakManager] = [:]

    private var lastHandle: Int64 = 0

    /// The newest fix any manager received: for true north.
    var lastFix: LocationFixValues?

    public init() { }

    /// Replaces the system, for tests.
    public func use(_ system: (any LocationSystem)?, permissions: (any PermissionSystem)? = nil) {
        _system = system
        _permissions = permissions
        managers = [:]
        lastFix = nil
    }

    fileprivate func add() -> Int64 {
        lastHandle += 1
        return lastHandle
    }

    func manager(_ handle: Int64) -> AndroidLocationManager? {
        managers[handle]?.manager
    }

    /// The authorization now; denied without a permission system.
    var authorization: (LocationAuthorization, LocationAccuracyAuthorization) {
        guard let permissions else {
            return (.denied, .full)
        }
        let grants = LocationMapping.grants(permissions)
        return (LocationMapping.authorization(grants, api: permissions.apiLevel), LocationMapping.accuracy(grants))
    }

    /// Asks for `requested`, then tells every manager what changed.
    func request(_ requested: [String]) {
        AndroidPermissions.request(requested) { [self] _ in
            authorizationMayHaveChanged()
        }
    }

    /// After a request, and when the app becomes active: the user may have
    /// changed it in Settings.
    public func authorizationMayHaveChanged() {
        for manager in managers.values.compactMap(\.manager) {
            manager.reportAuthorization()
        }
    }

    // MARK: Events

    public func location(handle: Int64, _ values: [Double]) {
        guard let fix = LocationFixValues(values) else { return }
        manager(handle)?.received(fix)
    }

    public func providerDisabled(handle: Int64) {
        manager(handle)?.providerDisabled()
    }

    public func heading(handle: Int64, azimuth: Double, status: Int32, estimate: Double, timestamp: Int64) {
        manager(handle)?.received(azimuth: azimuth, status: status, estimate: estimate, timestamp: timestamp)
    }
}

fileprivate struct WeakManager {
    weak var manager: AndroidLocationManager?
}
