import AndroidHost
import DynamicBackgroundTasks
import DynamicRuntime
import RuntimeBackgroundTasks
import RuntimeHost

/// What the app's background tasks ask of `WorkManager` (`Plan.md` §6.17):
/// the Kotlin `BackgroundTaskSystem`. Tests use a fake. Main thread only;
/// what the system does with the tasks comes back through
/// `BackgroundTaskHub`.
public protocol BackgroundTaskSystem: AnyObject {

    /// Whether the user restricted the app's background work in Settings.
    func restricted() -> Bool

    /// Asks for a task, replacing the request before: `kind` 0 refresh, 1
    /// processing; seconds; `interval` 0 for once; `requirements` bits 1
    /// network, 2 charging. 0, or -1 when `WorkManager` refused it.
    func submit(_ identifier: String, kind: Int32, earliest: Double, interval: Double, requirements: Int32) -> Int32

    func cancel(_ identifier: String)

    func cancelAll()

    /// Answered by `BackgroundTaskHub.listed` with `request`.
    func pending(_ request: Int32)

    /// The worker with `token` is done.
    func finished(_ token: Int32, success: Bool)
}

/// `HostBackgroundTasks`' scheduler on Android: `WorkManager`, which keeps
/// requests across launches and restarts and repeats a periodic one by
/// itself.
///
/// Nothing on Android holds a process for a moment's work, so an activity
/// the guest begins has already expired, and the app runs on only while
/// the system leaves it; the time left isn't known.
public final class AndroidBackgroundScheduler: BackgroundScheduler {

    let system: any BackgroundTaskSystem

    private var listings: [Int32: ([String]) -> Void] = [:]

    private var nextListing: Int32 = 1

    public init(system: any BackgroundTaskSystem) {
        self.system = system
    }

    /// Android's switch for the app is `isBackgroundRestricted`, off by
    /// default; nothing prompts for it.
    public var status: PermissionStatus {
        system.restricted() ? .denied : .granted
    }

    public var repeatsRequests: Bool {
        true
    }

    public func submit(_ request: HostBackgroundRequest, completion: @escaping (BackgroundError?) -> Void) {
        let code = system.submit(request.identifier, kind: request.kind.rawValue, earliest: request.earliest,
                                 interval: request.interval, requirements: request.requirements.rawValue)
        completion(code == 0 ? nil : .unknown)
    }

    public func cancel(_ identifier: String?) {
        if let identifier {
            system.cancel(identifier)
        } else {
            system.cancelAll()
        }
    }

    public func pending(_ completion: @escaping ([String]) -> Void) {
        let request = nextListing
        nextListing += 1
        listings[request] = completion
        system.pending(request)
    }

    func listed(_ request: Int32, identifiers: [String]) {
        listings.removeValue(forKey: request)?(identifiers)
    }
}

/// What `WorkManager` does with the app's tasks: the Kotlin side's
/// `BackgroundTaskNatives` call these on the main thread. Main thread only.
public final class BackgroundTaskHub {

    nonisolated(unsafe) public static let shared = BackgroundTaskHub()

    /// The scheduler, once `AndroidHostBackgroundTasks.configure` made it.
    var scheduler: AndroidBackgroundScheduler?

    public init() { }

    /// Task `identifier` is to run: the guest is told, and the worker with
    /// `token` hears how it went, which may be before this returns. The
    /// run's number.
    public func run(_ identifier: String, token: Int32) -> Int32 {
        let system = scheduler?.system
        return HostBackgroundTasks.start(identifier) { success in
            system?.finished(token, success: success)
        }
    }

    /// `WorkManager` stopped run `run` before it finished.
    public func expire(_ run: Int32) {
        HostBackgroundTasks.expire(run)
    }

    /// The tasks asked for and not over, one per line.
    public func listed(_ request: Int32, identifiers: String) {
        scheduler?.listed(request, identifiers: identifiers.split(separator: "\n").map(String.init))
    }
}

/// The background tasks contract (`Plan.md` §6.17): AppRuntime's
/// `HostBackgroundTasks`, which checks requests against the manifest's
/// tasks, numbers runs and activities, and tells the system how each run
/// went, over `WorkManager`. Needs `.backgroundTasks`, which asks Android
/// for no permission.
public enum AndroidHostBackgroundTasks: HostModule {

    public static var contracts: [ContractDescriptor] {
        HostBackgroundTasksModule.contracts
    }

    public static func register(in registrar: some ContractRegistrar) {
        HostBackgroundTasksModule.register(in: registrar)
    }

    public static func permissionProviders() -> [Capability: any PermissionProvider] {
        HostBackgroundTasksModule.permissionProviders()
    }

    /// Points `HostBackgroundTasks` at `WorkManager`, with the tasks the
    /// manifest names, and its answers at the main looper. Main thread.
    public static func configure(_ system: any BackgroundTaskSystem, declared: [String: BackgroundTaskKind]) {
        let scheduler = AndroidBackgroundScheduler(system: system)
        BackgroundTaskHub.shared.scheduler = scheduler
        HostBackgroundTasks.scheduler = scheduler
        HostBackgroundTasks.declared = declared
        HostBackgroundTasks.deliver = { job in MainLooper.shared.post(job) }
        HostBackgroundTasks.after = { seconds, job in
            _ = MainLooper.shared.schedule(after: Int64(seconds * 1_000_000_000), job)
        }
    }

    /// The tasks the manifest names, from the bundle's `RTBackgroundTasks`:
    /// each an `Identifier` and a `Kind`, `refresh` or `processing`.
    public static func declared(_ entries: [[String: String]]) -> [String: BackgroundTaskKind] {
        var tasks: [String: BackgroundTaskKind] = [:]
        for entry in entries {
            guard let identifier = entry["Identifier"], !identifier.isEmpty else { continue }
            switch entry["Kind"] {
            case "refresh": tasks[identifier] = .refresh
            case "processing": tasks[identifier] = .processing
            default: continue
            }
        }
        return tasks
    }
}
