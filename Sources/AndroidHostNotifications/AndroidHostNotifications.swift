import AndroidHost
import DynamicNotifications
import DynamicRuntime
import RuntimeHost
import RuntimeNotifications

/// The notifications module (`Plan.md` §6.9): AppRuntime's
/// `HostNotifications`, for both contracts, over `AndroidNotificationCenter`.
///
/// Push is `unsupported`: the host has no Firebase Cloud Messaging yet.
public enum AndroidHostNotifications: HostModule {

    /// The centre, once the host configures it. A process started for an
    /// alarm configures it too, with no guest.
    nonisolated(unsafe) public private(set) static var center: AndroidNotificationCenter?

    /// Points `HostNotifications` at Android's notifications; `declaresRemote`
    /// is the manifest's `.notifications(remote: true)`. Main thread.
    public static func configure(_ center: AndroidNotificationCenter, declaresRemote: Bool) {
        Self.center = center
        HostNotifications.presenter = center
        HostNotifications.declaresRemote = declaresRemote
        HostNotifications.deliver = { job in MainLooper.shared.post(job) }
        HostNotifications.refreshStatus()
    }

    public static var contracts: [ContractDescriptor] {
        HostNotificationsModule.contracts
    }

    public static func register(in registrar: some ContractRegistrar) {
        HostNotificationsModule.register(in: registrar)
    }

    public static func permissionProviders() -> [Capability: any PermissionProvider] {
        HostNotificationsModule.permissionProviders()
    }
}
