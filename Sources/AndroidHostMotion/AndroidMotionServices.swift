import AndroidHost
import DynamicMotion
import DynamicRuntime

/// The `motion` capability's authorization: `ACTIVITY_RECOGNITION` on API
/// 29+, nothing before.
enum MotionAuthorizer {

    static var status: MotionAuthorization {
        guard let system = AndroidPermissions.system,
              let requirement = AndroidPermissions.requirement(.motion, api: system.apiLevel) else {
            return .denied
        }
        return MotionMapping.authorization(AndroidPermissions.status(requirement, system: system))
    }

    /// Asks if the user hasn't decided; `completion` gets the status after.
    static func request(_ completion: @escaping (MotionAuthorization) -> Void) {
        guard status == .notDetermined, let system = AndroidPermissions.system,
              let requirement = AndroidPermissions.requirement(.motion, api: system.apiLevel) else {
            completion(status)
            return
        }
        AndroidPermissions.request(requirement.permissions) { _ in
            completion(status)
        }
    }
}

/// The `Altimeter` contract over `TYPE_PRESSURE`. Android's pressure
/// sensor needs no permission, so it's always authorized.
public final class AndroidAltimeter: Altimeter, SensorClient {

    let hub: MotionHub

    let delegate: any AltimeterDelegate

    private(set) var updating = false

    /// The pressure when updates started, in hPa.
    private var reference: Double?

    init(delegate: any AltimeterDelegate, hub: MotionHub = .shared) {
        self.delegate = delegate
        self.hub = hub
    }

    deinit {
        if updating {
            hub.unsubscribe(self, from: SensorType.pressure)
        }
    }

    public static func isAvailable() -> Bool {
        MotionHub.shared.system.hasSensor(SensorType.pressure)
    }

    public static func authorizationStatus() -> Int32 {
        MotionAuthorization.authorized.rawValue
    }

    public static func make(_ delegate: any AltimeterDelegate) -> AndroidAltimeter {
        AndroidAltimeter(delegate: delegate)
    }

    public func requestAuthorization() {
        delegate.didChangeAuthorization(self, status: MotionAuthorization.authorized.rawValue)
    }

    public func startUpdates() {
        guard !updating else { return }
        guard Self.isAvailable() else {
            delegate.didFail(self, error: MotionError.unavailable.rawValue)
            return
        }
        reference = nil
        // About once a second, like CoreMotion's altimeter.
        guard hub.subscribe(self, to: SensorType.pressure, period: 1_000_000) else {
            delegate.didFail(self, error: MotionError.unknown.rawValue)
            return
        }
        updating = true
    }

    public func stopUpdates() {
        guard updating else { return }
        updating = false
        hub.unsubscribe(self, from: SensorType.pressure)
    }

    func received(_ sample: SensorSample) {
        guard updating, let hectopascals = sample.values.first.map(Double.init), hectopascals > 0 else { return }
        let reference = reference ?? hectopascals
        self.reference = reference
        delegate.didUpdate(self, pressure: hectopascals / 10,
                           relativeAltitude: MotionMapping.altitude(pressure: hectopascals, reference: reference),
                           timestamp: sample.timestamp)
    }
}

/// The `Pedometer` contract over `TYPE_STEP_COUNTER`, which counts since
/// boot: counting starts at `startUpdates`, and there's no history,
/// distance or floors.
public final class AndroidPedometer: Pedometer, SensorClient {

    let hub: MotionHub

    let delegate: any PedometerDelegate

    private(set) var updating = false

    private var firstCount: UInt64?

    private var start: Int64 = 0

    private var lastAuthorization: MotionAuthorization?

    init(delegate: any PedometerDelegate, hub: MotionHub = .shared) {
        self.delegate = delegate
        self.hub = hub
    }

    deinit {
        if updating {
            hub.unsubscribe(self, from: SensorType.stepCounter)
        }
    }

    public static func isStepCountingAvailable() -> Bool {
        MotionHub.shared.system.hasSensor(SensorType.stepCounter)
    }

    public static func isDistanceAvailable() -> Bool { false }

    public static func isFloorCountingAvailable() -> Bool { false }

    public static func isHistoryAvailable() -> Bool { false }

    public static func authorizationStatus() -> Int32 {
        MotionAuthorizer.status.rawValue
    }

    public static func make(_ delegate: any PedometerDelegate) -> AndroidPedometer {
        AndroidPedometer(delegate: delegate)
    }

    public func requestAuthorization() {
        MotionAuthorizer.request { [weak self] status in
            guard let self else { return }
            delegate.didChangeAuthorization(self, status: status.rawValue)
        }
    }

    public func startUpdates(from start: Int64) {
        guard !updating else { return }
        guard MotionAuthorizer.status == .authorized else {
            delegate.didFail(self, error: MotionError.unauthorized.rawValue)
            return
        }
        guard Self.isStepCountingAvailable() else {
            delegate.didFail(self, error: MotionError.unavailable.rawValue)
            return
        }
        firstCount = nil
        self.start = MotionMapping.now()
        guard hub.subscribe(self, to: SensorType.stepCounter, period: 0) else {
            delegate.didFail(self, error: MotionError.unknown.rawValue)
            return
        }
        updating = true
    }

    public func stopUpdates() {
        guard updating else { return }
        updating = false
        hub.unsubscribe(self, from: SensorType.stepCounter)
    }

    public func query(from start: Int64, to end: Int64) {
        delegate.didQuery(self, steps: -1, distance: .nan, floorsAscended: -1, floorsDescended: -1,
                          start: start, end: end, error: MotionError.historyUnavailable.rawValue)
    }

    func received(_ sample: SensorSample) {
        guard updating else { return }
        let first = firstCount ?? sample.steps
        firstCount = first
        let steps = Int64(clamping: sample.steps &- first)
        delegate.didUpdate(self, steps: steps, distance: .nan, floorsAscended: -1, floorsDescended: -1,
                           start: start, end: MotionMapping.now())
    }
}

/// The `ActivityRecognizer` contract: activity recognition needs Google
/// Play services, which this host doesn't use, so it's unavailable.
public final class AndroidActivityRecognizer: ActivityRecognizer {

    let delegate: any ActivityRecognizerDelegate

    init(delegate: any ActivityRecognizerDelegate) {
        self.delegate = delegate
    }

    public static func isAvailable() -> Bool { false }

    public static func authorizationStatus() -> Int32 {
        MotionAuthorizer.status.rawValue
    }

    public static func make(_ delegate: any ActivityRecognizerDelegate) -> AndroidActivityRecognizer {
        AndroidActivityRecognizer(delegate: delegate)
    }

    public func requestAuthorization() {
        MotionAuthorizer.request { [weak self] status in
            guard let self else { return }
            delegate.didChangeAuthorization(self, status: status.rawValue)
        }
    }

    public func startUpdates() {
        delegate.didFail(self, error: MotionError.unavailable.rawValue)
    }

    public func stopUpdates() {}
}

/// The Motion contracts (`Plan.md` §6.2). `motion`'s permission comes from
/// `AndroidPermissions`' table.
public enum AndroidHostMotion: HostModule {

    public static var contracts: [ContractDescriptor] {
        [
            MotionManagerProxy.descriptor, MotionManagerDelegateProxy.descriptor,
            AltimeterProxy.descriptor, AltimeterDelegateProxy.descriptor,
            PedometerProxy.descriptor, PedometerDelegateProxy.descriptor,
            ActivityRecognizerProxy.descriptor, ActivityRecognizerDelegateProxy.descriptor,
        ]
    }

    public static func register(in registrar: some ContractRegistrar) {
        MotionManagerProxy.register(AndroidMotionManager.self, in: registrar)
        MotionManagerDelegateProxy.registerInterface(in: registrar)
        AltimeterProxy.register(AndroidAltimeter.self, in: registrar)
        AltimeterDelegateProxy.registerInterface(in: registrar)
        PedometerProxy.register(AndroidPedometer.self, in: registrar)
        PedometerDelegateProxy.registerInterface(in: registrar)
        ActivityRecognizerProxy.register(AndroidActivityRecognizer.self, in: registrar)
        ActivityRecognizerDelegateProxy.registerInterface(in: registrar)
    }
}
