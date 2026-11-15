/// What `HostBackground` asks Android, through the Kotlin
/// `org.pureswift.appruntime.contracts.BackgroundSystem` (`AndroidHostApp`
/// binds it). Main thread only.
public protocol BackgroundSystem: AnyObject {

    /// Runs the host's foreground service for `types`
    /// (`ServiceInfo.FOREGROUND_SERVICE_TYPE_*`), or stops it for 0.
    /// Only the types the manifest declares run; the ones that do.
    func run(types: Int32) -> Int32
}

/// The host's foreground service (`Plan.md` §6.2), which keeps location
/// updates and Bluetooth connections going while the app is in the
/// background, with a notification that says so.
///
/// Each kind of work runs while any object holds it. Android only lets an
/// app start a foreground service while it's in the foreground, so work
/// starts when the guest asks for it, not when the app leaves. The packager
/// declares the service for `location(.always)` and for Bluetooth's
/// `background` option; work the manifest doesn't declare doesn't run.
/// Main thread only.
public enum HostBackground {

    public enum Work: Int32, CaseIterable, Sendable {
        /// `FOREGROUND_SERVICE_TYPE_LOCATION`.
        case location = 8
        /// `FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE`.
        case bluetooth = 16
    }

    /// Set by `AndroidHostApp`.
    nonisolated(unsafe) public static var system: (any BackgroundSystem)?

    nonisolated(unsafe) private static var holders: [Work: Set<ObjectIdentifier>] = [:]

    /// The types the service runs with.
    nonisolated(unsafe) public private(set) static var running: Int32 = 0

    /// Holds or releases `work` for `owner`; whether `work` runs now.
    @discardableResult
    public static func set(_ work: Work, _ on: Bool, for owner: AnyObject) -> Bool {
        let id = ObjectIdentifier(owner)
        if on {
            holders[work, default: []].insert(id)
        } else {
            holders[work]?.remove(id)
        }
        update()
        return running & work.rawValue != 0
    }

    /// The types wanted now.
    static var wanted: Int32 {
        Work.allCases.filter { !(holders[$0]?.isEmpty ?? true) }.reduce(0) { $0 | $1.rawValue }
    }

    private static func update() {
        let wanted = self.wanted
        guard wanted != running || wanted == 0 && running != 0 else { return }
        guard let system else {
            running = 0
            return
        }
        running = system.run(types: wanted)
    }

    /// Forgets the holders, for tests.
    public static func reset() {
        holders = [:]
        running = 0
    }
}
