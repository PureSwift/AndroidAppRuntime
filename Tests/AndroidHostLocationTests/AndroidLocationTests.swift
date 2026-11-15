import AndroidHost
@testable import AndroidHostLocation
import DynamicLocation
import DynamicRuntime
import Testing

/// Location permissions, as the tests set them.
final class FakePermissions: PermissionSystem {

    var apiLevel: Int32 = 34
    var granted: Set<String> = []
    var requested: Set<String> = []
    var declared: Set<String> = [AndroidPermissions.fineLocation, AndroidPermissions.coarseLocation]
    var requests: [[String]] = []

    func isGranted(_ permission: String) -> Bool { granted.contains(permission) }
    func wasRequested(_ permission: String) -> Bool { requested.contains(permission) }
    func isDeclared(_ permission: String) -> Bool { declared.contains(permission) }
    func hasFeature(_ feature: String) -> Bool { true }

    func request(_ permissions: [String], id: Int32) -> Bool {
        requests.append(permissions)
        requested.formUnion(permissions)
        return true
    }
}

/// A location stack the tests drive.
final class FakeLocationSystem: LocationSystem {

    final class Source: LocationSource {
        var plans: [LocationPlan] = []
        var running = false
        var heading = false
        var refuse = false

        func start(_ plan: LocationPlan) -> Bool {
            guard !refuse else { return false }
            plans.append(plan)
            running = true
            return true
        }

        func stop() { running = false }

        func startHeading() -> Bool {
            heading = true
            return true
        }

        func stopHeading() { heading = false }
    }

    var enabled = true
    var enabledProviders = ["fused", "gps", "network"]
    var headingSensor = true
    var known: [LocationFixValues] = []
    var sources: [Int64: Source] = [:]

    func isLocationEnabled() -> Bool { enabled }
    func providers() -> [String] { enabledProviders }
    func hasHeadingSensor() -> Bool { headingSensor }
    func lastKnown() -> [LocationFixValues] { known }

    func declination(latitude: Double, longitude: Double, altitude: Double, time: Int64) -> Double { 10 }

    func makeSource(handle: Int64) -> any LocationSource {
        let source = Source()
        sources[handle] = source
        return source
    }
}

final class RecordingLocationDelegate: LocationManagerDelegate {

    var events: [String] = []
    var locations: [any Location] = []
    var headings: [any Heading] = []

    func didChangeAuthorization(_ manager: any LocationManager, status: Int32, accuracy: Int32) {
        events.append("authorization \(status) \(accuracy)")
    }

    func didUpdateLocations(_ manager: any LocationManager, locations: [any Location]) {
        events.append("locations \(locations.count)")
        self.locations += locations
    }

    func didUpdateHeading(_ manager: any LocationManager, heading: any Heading) {
        events.append("heading")
        headings.append(heading)
    }

    func didFail(_ manager: any LocationManager, error: Int32) {
        events.append("fail \(error)")
    }
}

/// Serialized: the hub and `AndroidPermissions` are shared.
@Suite(.serialized) struct AndroidLocationTests {

    let system = FakeLocationSystem()
    let permissions = FakePermissions()

    init() {
        AndroidPermissions.reset()
        AndroidPermissions.system = permissions
        LocationHub.shared.use(system, permissions: permissions)
    }

    func manager(_ delegate: RecordingLocationDelegate) -> AndroidLocationManager {
        AndroidLocationManager(delegate: delegate)
    }

    func source(_ manager: AndroidLocationManager) -> FakeLocationSystem.Source {
        _ = manager.source
        return system.sources[manager.handle]!
    }

    func fix(_ latitude: Double, at time: Int64 = 1_000) -> LocationFixValues {
        LocationFixValues(latitude: latitude, longitude: 2, horizontalAccuracy: 5, timestamp: time)
    }

    @Test func mapsAuthorization() {
        typealias Grants = LocationMapping.Grants
        #expect(LocationMapping.authorization(Grants(), api: 34) == .notDetermined)
        #expect(LocationMapping.authorization(Grants(requested: true), api: 34) == .denied)
        #expect(LocationMapping.authorization(Grants(coarse: true), api: 34) == .authorizedWhenInUse)
        #expect(LocationMapping.authorization(Grants(fine: true, background: true), api: 34) == .authorizedAlways)
        #expect(LocationMapping.authorization(Grants(fine: true), api: 28) == .authorizedAlways, "no background permission before 29")
        #expect(LocationMapping.authorization(Grants(fine: true, declared: false), api: 34) == .denied)
        #expect(LocationMapping.accuracy(Grants(coarse: true)) == .reduced)
        #expect(LocationMapping.accuracy(Grants(fine: true, coarse: true)) == .full)
        #expect(LocationMapping.accuracy(Grants()) == .full)
    }

    @Test func choosesProviders() {
        func plan(_ accuracy: LocationAccuracy, _ providers: [String], fine: Bool = true) -> LocationPlan? {
            LocationMapping.plan(accuracy, distanceFilter: 10, providers: providers, fine: fine)
        }
        #expect(plan(.best, ["fused", "gps", "network"]) == LocationPlan(provider: "fused", quality: 100, interval: 1_000, minimumDistance: 10))
        #expect(plan(.best, ["gps", "network"])?.provider == "gps")
        #expect(plan(.hundredMeters, ["gps", "network"]) == LocationPlan(provider: "network", quality: 102, interval: 5_000, minimumDistance: 10))
        #expect(plan(.best, ["gps", "network"], fine: false)?.provider == "network", "GPS needs fine location")
        #expect(plan(.kilometer, ["gps"])?.provider == "gps")
        #expect(plan(.best, ["gps"], fine: false) == nil)
        #expect(plan(.reduced, ["network"])?.quality == 104)
        #expect(LocationMapping.plan(.best, distanceFilter: -5, providers: ["fused"], fine: true)?.minimumDistance == 0)
    }

    @Test func mapsHeadings() {
        #expect(LocationMapping.headingAccuracy(status: 0, estimate: 0.1) == -1)
        #expect(LocationMapping.headingAccuracy(status: 3, estimate: 0) == 10)
        #expect(LocationMapping.headingAccuracy(status: 1, estimate: -1) == 35)
        #expect(abs(LocationMapping.headingAccuracy(status: 2, estimate: .pi / 18) - 10) < 0.0001)
        #expect(LocationMapping.normalized(-90) == 270)
        #expect(LocationMapping.normalized(725) == 5)
        #expect(LocationMapping.difference(359, 1) == 2)
        #expect(LocationFixValues([1, 2, .nan, 5, -1, -1, -1, -1, -1, 1000, 1]) == fix(1).withMock())
        #expect(LocationFixValues([1, 2]) == nil)
    }

    @Test func reportsAuthorizationOnceAndWhenItChanges() {
        let delegate = RecordingLocationDelegate()
        let manager = manager(delegate)
        manager.reportAuthorization()
        manager.reportAuthorization()
        #expect(delegate.events == ["authorization 0 0"])
        manager.requestWhenInUseAuthorization()
        #expect(permissions.requests == [[AndroidPermissions.fineLocation, AndroidPermissions.coarseLocation]])
        permissions.granted = [AndroidPermissions.coarseLocation]
        AndroidPermissions.didRequest(id: 1, permissions: [], granted: [])
        #expect(delegate.events == ["authorization 0 0", "authorization 4 1"])
        #expect(AndroidLocationManager.authorizationStatus() == LocationAuthorization.authorizedWhenInUse.rawValue)
        #expect(AndroidLocationManager.accuracyAuthorization() == LocationAccuracyAuthorization.reduced.rawValue)
        // The user upgrades in Settings; the manager hears it when the app comes back.
        permissions.granted.insert(AndroidPermissions.fineLocation)
        LocationHub.shared.authorizationMayHaveChanged()
        #expect(delegate.events.last == "authorization 4 0")
    }

    @Test func alwaysNeedsWhenInUseAndTheManifest() {
        let delegate = RecordingLocationDelegate()
        let manager = manager(delegate)
        manager.requestAlwaysAuthorization()
        #expect(permissions.requests.isEmpty)
        permissions.granted = [AndroidPermissions.fineLocation, AndroidPermissions.coarseLocation]
        manager.requestAlwaysAuthorization()
        #expect(delegate.events.last == "fail \(LocationError.denied.rawValue)", "no ACCESS_BACKGROUND_LOCATION in the manifest")
        permissions.declared.insert(AndroidPermissions.backgroundLocation)
        manager.requestAlwaysAuthorization()
        #expect(permissions.requests == [[AndroidPermissions.backgroundLocation]])
    }

    @Test func failsWithoutAuthorizationOrServices() {
        let delegate = RecordingLocationDelegate()
        let manager = manager(delegate)
        manager.startUpdatingLocation()
        #expect(delegate.events == ["fail \(LocationError.denied.rawValue)"])
        permissions.granted = [AndroidPermissions.fineLocation, AndroidPermissions.coarseLocation]
        system.enabled = false
        manager.startUpdatingLocation()
        #expect(delegate.events.last == "fail \(LocationError.servicesDisabled.rawValue)")
        system.enabled = true
        source(manager).refuse = true
        manager.startUpdatingLocation()
        #expect(delegate.events.last == "fail \(LocationError.denied.rawValue)")
        #expect(!manager.updating)
    }

    @Test func deliversUpdates() {
        permissions.granted = [AndroidPermissions.fineLocation, AndroidPermissions.coarseLocation]
        let delegate = RecordingLocationDelegate()
        let manager = manager(delegate)
        manager.setDesiredAccuracy(LocationAccuracy.hundredMeters.rawValue)
        manager.setDistanceFilter(25)
        manager.startUpdatingLocation()
        let source = source(manager)
        #expect(source.plans == [LocationPlan(provider: "fused", quality: 102, interval: 5_000, minimumDistance: 25)])
        LocationHub.shared.location(handle: manager.handle, [48.8, 2.3, 35, 5, 3, 1.5, 0.5, 90, 10, 1_700_000_000_000, 0])
        #expect(delegate.events == ["locations 1"])
        let location = delegate.locations[0]
        #expect(location.latitude() == 48.8)
        #expect(location.altitude() == 35)
        #expect(location.timestamp() == 1_700_000_000_000)
        #expect(location.isSimulated() == 0)
        // A new accuracy restarts the source.
        manager.setDesiredAccuracy(LocationAccuracy.best.rawValue)
        #expect(source.plans.last?.quality == 100)
        manager.stopUpdatingLocation()
        #expect(!source.running)
        // Another manager's fix doesn't reach this one.
        LocationHub.shared.location(handle: manager.handle + 1, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 0])
        #expect(delegate.events == ["locations 1"])
    }

    @Test func requestsOneLocation() {
        permissions.granted = [AndroidPermissions.fineLocation, AndroidPermissions.coarseLocation]
        let delegate = RecordingLocationDelegate()
        let manager = manager(delegate)
        manager.requestLocation()
        let source = source(manager)
        #expect(source.running)
        manager.received(fix(1))
        manager.received(fix(2))
        #expect(delegate.events == ["locations 1"])
        #expect(!source.running, "one fix, then it stops")
        // With continuous updates on, the one-shot leaves them running.
        manager.startUpdatingLocation()
        manager.requestLocation()
        manager.received(fix(3))
        #expect(source.running)
    }

    @Test func readsTheNewestLastLocation() {
        let manager = manager(RecordingLocationDelegate())
        system.known = [fix(1, at: 5), fix(2, at: 9), fix(3, at: 7)]
        #expect(manager.lastLocation() == nil, "not authorized")
        permissions.granted = [AndroidPermissions.coarseLocation]
        #expect(manager.lastLocation()?.latitude() == 2)
    }

    @Test func deliversHeadings() {
        let delegate = RecordingLocationDelegate()
        let manager = manager(delegate)
        manager.startUpdatingHeading()
        let hub = LocationHub.shared
        hub.heading(handle: manager.handle, azimuth: -90, status: 3, estimate: 0, timestamp: 1)
        hub.heading(handle: manager.handle, azimuth: -89.5, status: 3, estimate: 0, timestamp: 2)
        #expect(delegate.headings.count == 1, "under a degree isn't reported")
        #expect(delegate.headings[0].magneticHeading() == 270)
        #expect(delegate.headings[0].trueHeading() == -1, "no location yet")
        manager.received(fix(1))
        hub.heading(handle: manager.handle, azimuth: 355, status: 3, estimate: 0, timestamp: 3)
        #expect(delegate.headings.last?.trueHeading() == 5, "declination 10° east")
        manager.stopUpdatingHeading()
        #expect(!source(manager).heading)
    }

    @Test func holdsTheForegroundServiceForBackgroundUpdates() {
        final class Service: BackgroundSystem {
            var runs: [Int32] = []
            func run(types: Int32) -> Int32 {
                runs.append(types)
                return types
            }
        }
        let service = Service()
        HostBackground.reset()
        HostBackground.system = service
        defer { HostBackground.system = nil }
        permissions.granted = [AndroidPermissions.fineLocation, AndroidPermissions.coarseLocation]
        let delegate = RecordingLocationDelegate()
        var manager: AndroidLocationManager? = self.manager(delegate)
        manager?.setBackgroundUpdatesEnabled(true)
        #expect(delegate.events == ["fail \(LocationError.backgroundNotAllowed.rawValue)"], "when-in-use only")
        manager?.startUpdatingLocation()
        #expect(service.runs.isEmpty)
        permissions.granted.insert(AndroidPermissions.backgroundLocation)
        manager?.setBackgroundUpdatesEnabled(true)
        #expect(service.runs == [HostBackground.Work.location.rawValue])
        manager?.stopUpdatingLocation()
        #expect(service.runs.last == 0)
        manager?.startUpdatingLocation()
        #expect(service.runs.last == HostBackground.Work.location.rawValue)
        manager = nil
        #expect(service.runs.last == 0, "a released manager lets the service go")
    }

    @Test func registersEveryContract() {
        #expect(AndroidHostLocation.contracts.map(\.name) == [
            "org.pureswift.location.LocationManager", "org.pureswift.location.LocationManagerDelegate",
            "org.pureswift.location.Location", "org.pureswift.location.Heading",
        ])
    }
}

extension LocationFixValues {
    func withMock() -> LocationFixValues {
        var fix = self
        fix.isMock = true
        fix.horizontalAccuracy = 5
        return fix
    }
}
