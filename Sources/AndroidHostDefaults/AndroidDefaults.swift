import DynamicDefaults
import DynamicRuntime
import RuntimeHost

/// What `AndroidDefaultsStorage` asks Android, through the Kotlin
/// `org.pureswift.appruntime.contracts.DefaultsSystem` (`AndroidHostApp`
/// binds it): one `SharedPreferences` file of the app's own, holding
/// strings. Main thread only.
public protocol PreferencesSystem: AnyObject {

    func contains(_ key: String) -> Bool

    /// The string at `key`; empty when there's none.
    func string(_ key: String) -> String

    /// Puts `value` at `key` and removes `removing`, in one edit, applied.
    func set(_ key: String, value: String, removing: String)

    /// Removes the keys, in one edit, applied.
    func remove(_ keys: [String])

    /// Every key, in any order.
    func keys() -> [String]
}

/// The `Defaults` contract's storage on Android (`Plan.md` §6.6):
/// `SharedPreferences`, which has no byte type. So each key is marked with
/// its value's kind: a string at `s:<key>`, bytes as Base64 at `d:<key>`.
/// Setting one kind removes the other.
///
/// `apply()` writes in the background, and Android waits for it when the
/// Activity stops, so a value that was set is there at the next launch.
public final class AndroidDefaultsStorage: DefaultsStorage {

    static let stringMark = "s:"

    static let dataMark = "d:"

    /// The largest value kept, in bytes; bytes count before Base64. A
    /// larger one is refused.
    public let maximumValueSize: Int

    private let makeSystem: () -> (any PreferencesSystem)?

    private var made: (any PreferencesSystem)??

    /// `makeSystem` runs the first time a value is read or written.
    public init(maximumValueSize: Int = 64 << 10, makeSystem: @escaping () -> (any PreferencesSystem)?) {
        self.maximumValueSize = maximumValueSize
        self.makeSystem = makeSystem
    }

    private var system: (any PreferencesSystem)? {
        if let made {
            return made
        }
        let system = makeSystem()
        made = .some(system)
        return system
    }

    public func string(_ key: String) -> String? {
        guard let system, system.contains(Self.stringMark + key) else { return nil }
        return system.string(Self.stringMark + key)
    }

    public func data(_ key: String) -> [UInt8]? {
        guard let system, system.contains(Self.dataMark + key) else { return nil }
        // A value that isn't Base64 was put there by something else.
        return Base64.decode(system.string(Self.dataMark + key))
    }

    public func setString(_ value: String, key: String) -> Bool {
        guard let system, value.utf8.count <= maximumValueSize else { return false }
        system.set(Self.stringMark + key, value: value, removing: Self.dataMark + key)
        return true
    }

    public func setData(_ value: [UInt8], key: String) -> Bool {
        guard let system, value.count <= maximumValueSize else { return false }
        system.set(Self.dataMark + key, value: Base64.encode(value), removing: Self.stringMark + key)
        return true
    }

    public func remove(_ key: String) {
        system?.remove([Self.stringMark + key, Self.dataMark + key])
    }

    /// The keys with a value of either kind; others in the file are left
    /// out.
    public func keys() -> [String] {
        var keys = Set<String>()
        for stored in system?.keys() ?? [] {
            if stored.hasPrefix(Self.stringMark) {
                keys.insert(String(stored.dropFirst(Self.stringMark.count)))
            } else if stored.hasPrefix(Self.dataMark) {
                keys.insert(String(stored.dropFirst(Self.dataMark.count)))
            }
        }
        return Array(keys)
    }
}

/// The defaults module: `HostDefaults` over `AndroidDefaultsStorage`.
public enum AndroidHostDefaults: HostModule {

    public static var contracts: [ContractDescriptor] {
        HostDefaultsModule.contracts
    }

    public static func register(in registrar: some ContractRegistrar) {
        HostDefaultsModule.register(in: registrar)
    }
}

/// Standard Base64, with padding.
enum Base64 {

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

    static func encode(_ bytes: [UInt8]) -> String {
        var output: [UInt8] = []
        output.reserveCapacity((bytes.count + 2) / 3 * 4)
        var index = 0
        while index < bytes.count {
            let count = min(3, bytes.count - index)
            var chunk: UInt32 = 0
            for offset in 0..<3 {
                chunk <<= 8
                if offset < count {
                    chunk |= UInt32(bytes[index + offset])
                }
            }
            for position in 0..<4 {
                if position <= count {
                    output.append(alphabet[Int((chunk >> UInt32(18 - position * 6)) & 0x3F)])
                } else {
                    output.append(UInt8(ascii: "="))
                }
            }
            index += 3
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// `nil` when `text` isn't Base64.
    static func decode(_ text: String) -> [UInt8]? {
        var values: [UInt8] = []
        var padding = 0
        for character in text.utf8 {
            switch character {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): values.append(character - UInt8(ascii: "A"))
            case UInt8(ascii: "a")...UInt8(ascii: "z"): values.append(character - UInt8(ascii: "a") + 26)
            case UInt8(ascii: "0")...UInt8(ascii: "9"): values.append(character - UInt8(ascii: "0") + 52)
            case UInt8(ascii: "+"): values.append(62)
            case UInt8(ascii: "/"): values.append(63)
            case UInt8(ascii: "="):
                padding += 1
                continue
            default:
                return nil
            }
            guard padding == 0 else { return nil }
        }
        guard (values.count + padding) % 4 == 0, padding <= 2, values.count % 4 != 1 else {
            return nil
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(values.count * 3 / 4)
        var index = 0
        while index < values.count {
            let count = min(4, values.count - index)
            var chunk: UInt32 = 0
            for offset in 0..<4 {
                chunk <<= 6
                if offset < count {
                    chunk |= UInt32(values[index + offset])
                }
            }
            for position in 0..<(count - 1) {
                bytes.append(UInt8((chunk >> UInt32(16 - position * 8)) & 0xFF))
            }
            index += 4
        }
        return bytes
    }
}
