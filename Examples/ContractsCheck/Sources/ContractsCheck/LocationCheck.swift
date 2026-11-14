import DynamicLocation
import DynamicRuntime

/// `LocationManager`: the authorization prompt (the script taps "While
/// using the app"), then one location and updates from the emulator's
/// GPS, which the script sets, and the heading.
final class LocationCheck: LocationManagerDelegate {

    let report: Report

    var manager: LocationManager?

    private var authorizations = 0

    private var requestedOnce = false

    private var updates = 0

    /// The last position reported, in 1/10 000 degree.
    private var lastPosition: (Int, Int)?

    private var sawHeading = false

    init(report: Report) {
        self.report = report
    }

    func run() {
        let status = LocationManagerProxy.authorizationStatus()
        report.check(status == LocationAuthorization.notDetermined.rawValue, "location.authorizationStatus \(status)")
        report.check(LocationManagerProxy.isLocationServicesEnabled(), "location.isLocationServicesEnabled")
        report.note("location.isHeadingAvailable \(LocationManagerProxy.isHeadingAvailable())")
        manager = LocationManagerProxy.make(self)
    }

    func didChangeAuthorization(_ manager: LocationManager, status: Int32, accuracy: Int32) {
        authorizations += 1
        if authorizations == 1 {
            report.check(status == LocationAuthorization.notDetermined.rawValue, "location.didChangeAuthorization first \(status)")
            report.note("location.requesting")
            manager.requestWhenInUseAuthorization()
            return
        }
        report.check(status == LocationAuthorization.authorizedWhenInUse.rawValue, "location.didChangeAuthorization \(status) \(accuracy)")
        Checks.startBluetooth()
        guard !requestedOnce, status == LocationAuthorization.authorizedWhenInUse.rawValue else { return }
        requestedOnce = true
        manager.requestLocation()
    }

    func didUpdateLocations(_ manager: LocationManager, locations: [Location]) {
        guard let location = locations.last else {
            report.check(false, "location.didUpdateLocations empty")
            return
        }
        // In 1/10 000 degree (about 11 m), so the script can match them: the
        // emulator's fixes are floats. Each new position once.
        let latitude = Int((location.latitude() * 10_000).rounded())
        let longitude = Int((location.longitude() * 10_000).rounded())
        if let lastPosition, lastPosition == (latitude, longitude) {
            return
        }
        lastPosition = (latitude, longitude)
        updates += 1
        report.check(location.timestamp() > 0, "location.update \(updates) \(latitude) \(longitude)")
        if updates == 1 {
            report.check(manager.lastLocation() != nil, "location.lastLocation")
            manager.setDesiredAccuracy(LocationAccuracy.best.rawValue)
            manager.startUpdatingLocation()
            manager.startUpdatingHeading()
        }
    }

    func didUpdateHeading(_ manager: LocationManager, heading: Heading) {
        guard !sawHeading else { return }
        sawHeading = true
        let magnetic = heading.magneticHeading()
        report.check(magnetic >= 0 && magnetic < 360, "location.didUpdateHeading")
    }

    func didFail(_ manager: LocationManager, error: Int32) {
        report.check(false, "location.didFail \(error)")
    }
}
