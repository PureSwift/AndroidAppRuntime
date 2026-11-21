import DynamicRuntime
import RuntimeCoreModel
import RuntimeHost

/// The model store module: `ModelStore` and the objects it's used with,
/// AppRuntime's `HostModelStore` over CoreModel-SQLite.
public enum AndroidHostModelStore: HostModule {

    public static var contracts: [ContractDescriptor] {
        HostModelStoreModule.contracts
    }

    public static func register(in registrar: some ContractRegistrar) {
        HostModelStoreModule.register(in: registrar)
    }

    /// Keeps stores in `directory`, the app's databases directory, and
    /// answers through `deliver`, which runs a job on the main thread.
    public static func configure(directory: String, deliver: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void) {
        HostModelStore.configure(.init(provider: SQLiteModelStorageProvider(directory: directory), deliver: deliver))
    }
}
