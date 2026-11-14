import DynamicRuntime
import RuntimeABI

/// What `AndroidPermissions` asks Android, through the Kotlin
/// `org.pureswift.appruntime.contracts.PermissionSystem` (`AndroidHostApp`
/// binds it). Main thread only.
public protocol PermissionSystem: AnyObject {

    /// `Build.VERSION.SDK_INT`.
    var apiLevel: Int32 { get }

    /// `checkSelfPermission`.
    func isGranted(_ permission: String) -> Bool

    /// Whether the user answered a request for `permission` before, from a
    /// flag the system keeps in `SharedPreferences`: Android has no "not
    /// determined". A request in flight hasn't been answered.
    func wasRequested(_ permission: String) -> Bool

    /// Whether the app's manifest declares `permission`.
    func isDeclared(_ permission: String) -> Bool

    /// `PackageManager.hasSystemFeature`.
    func hasFeature(_ feature: String) -> Bool

    /// `ActivityCompat.requestPermissions` with request code `id`; false if
    /// there's no Activity to ask from. The answer goes to
    /// `AndroidPermissions.didRequest`.
    func request(_ permissions: [String], id: Int32) -> Bool
}

/// The `Permissions` built-in on Android's runtime permissions (`Plan.md`
/// §6.1): which permissions each capability needs on this API level, their
/// status, and the requests in flight. Main thread only.
public enum AndroidPermissions {

    /// Set by `AndroidHostApp` before the app starts.
    nonisolated(unsafe) public static var system: (any PermissionSystem)?

    nonisolated(unsafe) private static var pending: [Int32: ([String: Bool]) -> Void] = [:]

    nonisolated(unsafe) private static var lastID: Int32 = 0

    // MARK: Capabilities

    /// What a capability needs: runtime permissions (none for install-time
    /// ones) and a hardware feature.
    public struct Requirement: Equatable, Sendable {

        public var permissions: [String]

        /// A `PackageManager.FEATURE_*` the device must have.
        public var feature: String?

        /// Permissions that grant it in part, such as coarse location.
        public var partial: [String] = []

        public init(permissions: [String], feature: String? = nil, partial: [String] = []) {
            self.permissions = permissions
            self.feature = feature
            self.partial = partial
        }
    }

    public static let fineLocation = "android.permission.ACCESS_FINE_LOCATION"
    public static let coarseLocation = "android.permission.ACCESS_COARSE_LOCATION"
    public static let backgroundLocation = "android.permission.ACCESS_BACKGROUND_LOCATION"

    /// The table in §6.1, for API level `api`. Capabilities with no prompt
    /// on Android (`network`, `graphics`) aren't here: they're granted.
    public static func requirement(_ capability: Capability, api: Int32) -> Requirement? {
        switch capability {
        case .bluetooth:
            let permissions = api >= 31
                ? ["android.permission.BLUETOOTH_SCAN", "android.permission.BLUETOOTH_CONNECT"]
                : [fineLocation]
            return Requirement(permissions: permissions, feature: "android.hardware.bluetooth_le")
        case .location:
            return Requirement(permissions: [fineLocation, coarseLocation], feature: "android.hardware.location",
                               partial: [coarseLocation])
        case .motion:
            return Requirement(permissions: api >= 29 ? ["android.permission.ACTIVITY_RECOGNITION"] : [])
        case .notifications:
            return Requirement(permissions: api >= 33 ? ["android.permission.POST_NOTIFICATIONS"] : [])
        case .camera:
            return Requirement(permissions: ["android.permission.CAMERA"], feature: "android.hardware.camera.any")
        case .nfc:
            return Requirement(permissions: [], feature: "android.hardware.nfc")
        default:
            return nil
        }
    }

    /// A provider for each capability in the table: what the `Permissions`
    /// built-in answers before modules add their own.
    public static func providers(api: Int32) -> [Capability: any PermissionProvider] {
        var providers: [Capability: any PermissionProvider] = [:]
        for capability in [Capability.bluetooth, .location, .motion, .notifications, .camera, .nfc] {
            if let requirement = requirement(capability, api: api) {
                providers[capability] = RuntimePermission(requirement)
            }
        }
        providers[.network] = GrantedPermission()
        return providers
    }

    // MARK: Status

    /// - The device lacks the feature: unavailable.
    /// - The manifest doesn't declare a permission: denied (the packager
    ///   declares them, so this means a hand-made manifest).
    /// - Every permission granted: granted. Only the partial ones: limited.
    /// - Otherwise denied once asked, and not determined before.
    public static func status(_ requirement: Requirement, system: any PermissionSystem) -> PermissionStatus {
        if let feature = requirement.feature, !system.hasFeature(feature) {
            return .unavailable
        }
        let permissions = requirement.permissions
        guard permissions.allSatisfy(system.isDeclared) else {
            return .denied
        }
        let granted = permissions.filter(system.isGranted)
        if granted.count == permissions.count {
            return .granted
        }
        if !granted.isEmpty, Set(granted).isSubset(of: requirement.partial) {
            return .limited
        }
        return permissions.contains(where: system.wasRequested) ? .denied : .notDetermined
    }

    // MARK: Requests

    /// Asks for `permissions`; `completion` gets each one's result, once, on
    /// the main thread. Without an Activity, or a system, nothing is
    /// granted.
    public static func request(_ permissions: [String], completion: @escaping ([String: Bool]) -> Void) {
        guard let system, !permissions.isEmpty else {
            completion([:])
            return
        }
        lastID = lastID >= 0x7FFF ? 1 : lastID + 1
        let id = lastID
        pending[id] = completion
        if !system.request(permissions, id: id) {
            pending[id] = nil
            completion(Dictionary(uniqueKeysWithValues: permissions.map { ($0, false) }))
        }
    }

    /// `onRequestPermissionsResult`: the shell forwards it.
    public static func didRequest(id: Int32, permissions: [String], granted: [Bool]) {
        guard let completion = pending.removeValue(forKey: id) else { return }
        var results: [String: Bool] = [:]
        for (permission, granted) in zip(permissions, granted) {
            results[permission] = granted
        }
        completion(results)
    }

    /// Forgets requests in flight; for tests.
    public static func reset() {
        pending = [:]
        lastID = 0
    }
}

/// One capability's runtime permissions.
public final class RuntimePermission: PermissionProvider {

    public let requirement: AndroidPermissions.Requirement

    public init(_ requirement: AndroidPermissions.Requirement) {
        self.requirement = requirement
    }

    public func status() -> PermissionStatus {
        guard let system = AndroidPermissions.system else {
            return .unavailable
        }
        return AndroidPermissions.status(requirement, system: system)
    }

    /// Asks only when the user can still be asked; the answer is the
    /// status afterwards.
    public func request(_ completion: @escaping (PermissionStatus) -> Void) {
        let status = status()
        guard status == .notDetermined || status == .denied || status == .limited else {
            completion(status)
            return
        }
        AndroidPermissions.request(requirement.permissions) { [self] _ in
            completion(self.status())
        }
    }
}
