import DynamicRuntime
import RuntimeABI
import RuntimeCore
@_exported import RuntimeHost
import RuntimeNative

/// Starts an app (`Plan.md` §5): checks it against this host, sets up the
/// runtime, registers the built-ins and the modules it uses, and calls
/// `rt_main`. Main thread only.
public final class AppHost {

    public let info: AppInfo

    public let modules: [any HostModule.Type]

    public let native: NativeRuntime

    /// Warnings from the last `prepare()`, such as a contract this host
    /// implements at a lower version than the app was built against.
    public private(set) var warnings: [String] = []

    public init(
        info: AppInfo,
        modules: [any HostModule.Type],
        native: NativeRuntime = .shared,
        clock: HostClock = MainLooperClock()
    ) {
        self.info = info
        self.modules = modules
        self.native = native
        native.runtime.clock = clock
    }

    /// Checks the app and registers everything it may use. Throws if the app
    /// needs more than this host has: the packager checked the same, so it
    /// means a corrupt app.
    public func prepare() throws(AppHostError) {
        warnings = try AppCompatibility.check(info, provided: AppCompatibility.providedContracts(modules))
        native.bindDirectly()
        native.capabilities = info.capabilities
        registerBuiltins()
        let used = info.contractNames
        for module in modules where module.isUsed(by: used) {
            module.register(in: native)
        }
        for warning in warnings {
            HostLog.warning(warning)
        }
    }

    /// Calls the app's `rt_main`. Afterwards the app runs only when Android
    /// calls in: events, listeners, timers and lifecycle.
    @discardableResult
    public func start(_ entry: AppEntryPoints) -> RuntimeStatus {
        let status = native.start(entry.main, dispatch: entry.dispatch, finalize: entry.finalize)
        if status != .ok {
            HostLog.error("rt_main failed: \(status)")
        }
        return status
    }

    // MARK: Built-ins

    /// Runtime permissions for the capabilities in §6.1's table, then each
    /// module's own providers.
    private func registerBuiltins() {
        var providers: [Capability: any PermissionProvider] = [:]
        if let system = AndroidPermissions.system {
            providers = AndroidPermissions.providers(api: system.apiLevel)
        }
        for module in modules {
            providers.merge(module.permissionProviders()) { _, module in module }
        }
        HostPermissions.providers = providers
        HostPermissions.declared = info.capabilities
        PermissionsProxy.register(HostPermissions.self, in: native)
        PermissionsDelegateProxy.registerInterface(in: native)
        AndroidBundle.info = info
        AppBundleProxy.register(AndroidBundle.self, in: native)
        ApplicationProxy.register(HostApplication.self, in: native)
        ApplicationDelegateProxy.registerInterface(in: native)
    }
}
