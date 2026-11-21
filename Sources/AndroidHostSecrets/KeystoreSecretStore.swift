import AndroidHost
import DynamicRuntime
import DynamicSecrets
import RuntimeHost
import RuntimeSecrets

/// What `KeystoreSecretStore` asks Android, through the Kotlin
/// `org.pureswift.appruntime.contracts.SecretSystem` (`AndroidHostApp` binds
/// it). Called on the secrets queue, one call at a time. Each call leaves
/// a `KeychainError` raw value for `error()`: 0 when it succeeded.
public protocol SecretSystem: AnyObject {

    func error() -> Int32

    /// Whether the last `value` found one.
    func found() -> Bool

    func set(_ key: String, value: [UInt8])
    func value(_ key: String) -> [UInt8]
    func remove(_ key: String)
    func removeAll()

    /// The keys, in any order.
    func keys() -> [String]
}

/// The app's secrets on Android (`Plan.md` §6.12): an AES-GCM key in the
/// Android Keystore, and each secret encrypted with it in a file of
/// `noBackupFilesDir`, so it's neither backed up nor readable by another
/// app, and goes with the app.
///
/// A Keystore key works while the device is locked, so both
/// accessibilities read alike.
public final class KeystoreSecretStore: SecretStore, @unchecked Sendable {

    let system: any SecretSystem

    public init(system: any SecretSystem) {
        self.system = system
    }

    private func check() throws(KeychainError) {
        let code = system.error()
        guard code == 0 else {
            throw KeychainError(rawValue: code) ?? .unknown
        }
    }

    public func set(_ key: String, value: [UInt8], accessibility: KeychainAccessibility) throws(KeychainError) {
        system.set(key, value: value)
        try check()
    }

    public func value(forKey key: String) throws(KeychainError) -> [UInt8]? {
        let value = system.value(key)
        try check()
        return system.found() ? value : nil
    }

    public func remove(_ key: String) throws(KeychainError) {
        system.remove(key)
        try check()
    }

    public func removeAll() throws(KeychainError) {
        system.removeAll()
        try check()
    }

    public func keys() throws(KeychainError) -> [String] {
        let keys = system.keys()
        try check()
        return keys
    }
}

/// The secrets module (`Plan.md` §6.12).
public enum AndroidHostSecrets: HostModule {

    /// Points `HostSecrets` at the Keystore. Main thread.
    public static func configure(_ store: KeystoreSecretStore) {
        HostSecrets.store = store
        HostSecrets.deliver = { job in MainLooper.shared.post(job) }
    }

    public static var contracts: [ContractDescriptor] {
        HostSecretsModule.contracts
    }

    public static func register(in registrar: some ContractRegistrar) {
        HostSecretsModule.register(in: registrar)
    }

    public static func permissionProviders() -> [Capability: any PermissionProvider] {
        HostSecretsModule.permissionProviders()
    }
}
