import DynamicBluetooth
import DynamicRuntime

/// Android's Bluetooth values to the contract's. Pure, so tests check them
/// on macOS.
enum BluetoothMapping {

    // MARK: UUIDs

    static let baseSuffix = "-0000-1000-8000-00805F9B34FB"

    /// A contract UUID string (4, 8 or 36 characters) as Android's 128-bit
    /// form; nil if it's none of them.
    static func expand(_ raw: String) -> String? {
        let upper = raw.uppercased()
        guard upper.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return nil }
        switch upper.count {
        case 4: return "0000" + upper + baseSuffix
        case 8: return upper + baseSuffix
        case 36: return upper
        default: return nil
        }
    }

    /// Android's 128-bit form in the shortest form that represents it.
    static func shorten(_ full: String) -> String {
        let upper = full.uppercased()
        guard upper.count == 36, upper.hasSuffix(baseSuffix) else { return upper }
        let prefix = upper.prefix(8)
        return prefix.hasPrefix("0000") ? String(prefix.dropFirst(4)) : String(prefix)
    }

    static func uuid(_ full: String) throws(RuntimeError) -> BluetoothUUID {
        guard let uuid = BluetoothUUID(rawValue: shorten(full)) else {
            throw RuntimeError.thrown("not a Bluetooth UUID: \(full)")
        }
        return uuid
    }

    // MARK: State

    /// `BluetoothAdapter.STATE_*`.
    enum AdapterState {
        static let off: Int32 = 10
        static let turningOn: Int32 = 11
        static let on: Int32 = 12
        static let turningOff: Int32 = 13
    }

    static func state(hasLowEnergy: Bool, authorization: BluetoothAuthorization, adapter: Int32) -> CentralState {
        guard hasLowEnergy, adapter >= 0 else {
            return .unsupported
        }
        guard authorization == .allowed else {
            return .unauthorized
        }
        switch adapter {
        case AdapterState.on: return .poweredOn
        case AdapterState.turningOn: return .resetting
        case AdapterState.off, AdapterState.turningOff: return .poweredOff
        default: return .unknown
        }
    }

    static func authorization(_ status: PermissionStatus) -> BluetoothAuthorization {
        switch status {
        case .granted, .unavailable: .allowed
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied, .limited: .denied
        }
    }

    /// The error for an operation when the central can't run it.
    static func error(for state: CentralState) -> BluetoothError? {
        switch state {
        case .poweredOn: nil
        case .unauthorized: .unauthorized
        case .unsupported: .unsupported
        default: .poweredOff
        }
    }

    // MARK: Scanning

    /// `ScanSettings.SCAN_MODE_*` for a `ScanMode`.
    static func scanMode(_ mode: Int32) -> Int32 {
        switch ScanMode(rawValue: mode) ?? .balanced {
        case .lowPower: 0
        case .balanced: 1
        case .lowLatency: 2
        }
    }

    /// `ScanCallback.SCAN_FAILED_*` to the contract's code.
    static func scanError(_ code: Int32) -> BluetoothError {
        switch code {
        case 6: .scanThrottled
        case 4: .unsupported
        default: .scanFailed
        }
    }

    /// Android allows five scan starts in 30 seconds, and then silently
    /// finds nothing; the host says so instead.
    static let scanStartLimit = 5

    static let scanStartWindow: Int64 = 30_000_000_000

    static func isThrottled(_ starts: [Int64], now: Int64) -> Bool {
        starts.filter { now - $0 < scanStartWindow }.count >= scanStartLimit
    }

    // MARK: GATT

    /// `BluetoothGatt.GATT_*` and HCI codes from a connection change to the
    /// contract's code: 0 for a disconnect the app asked for.
    static func disconnectError(status: Int32, requested: Bool) -> Int32 {
        if requested {
            return 0
        }
        switch status {
        case 0, 19: return BluetoothError.peripheralDisconnected.rawValue
        case 8: return BluetoothError.connectionTimeout.rawValue
        case 22: return 0
        default: return BluetoothError.peripheralDisconnected.rawValue
        }
    }

    static func connectError(status: Int32) -> BluetoothError {
        switch status {
        case 8, 147: .connectionTimeout
        case 257, 0x101: .connectionLimitReached
        default: .connectionFailed
        }
    }

    /// An operation's GATT status: ATT errors (1 to 0x7F) as `attribute`
    /// plus the code, as the contract says.
    static func operationError(_ status: Int32) -> Int32 {
        switch status {
        case 0: 0
        case 1...0x7F: BluetoothError.attribute.rawValue + status
        case 0x8F: BluetoothError.unknown.rawValue
        default: BluetoothError.unknown.rawValue
        }
    }

    /// The largest ATT MTU; Android 14+ always asks for it.
    static let maximumMTU: Int32 = 517

    /// `BluetoothGattCharacteristic.PROPERTY_*`.
    enum Property {
        static let notify: Int32 = 0x10
        static let indicate: Int32 = 0x20
    }

    static let cccd = "00002902" + baseSuffix

    /// The CCCD value for a subscription: notifications when the
    /// characteristic has them, otherwise indications.
    static func cccdValue(enabled: Bool, properties: Int32) -> [UInt8] {
        guard enabled else { return [0, 0] }
        return properties & Property.notify != 0 ? [1, 0] : [2, 0]
    }

    /// `WRITE_TYPE_DEFAULT` (2) or `WRITE_TYPE_NO_RESPONSE` (1).
    static func writeType(_ type: WriteType) -> Int32 {
        type == .withResponse ? 2 : 1
    }
}

/// An advertisement's AD structures (Core Specification Supplement, Part
/// A), from Android's `ScanRecord.getBytes()`.
struct AdvertisementData: Equatable {

    var localName: String?

    var manufacturerData: [UInt8]?

    /// 128-bit strings.
    var serviceUUIDs: [String] = []

    var serviceData: [(uuid: String, data: [UInt8])] = []

    var solicitedServiceUUIDs: [String] = []

    var txPowerLevel: Int32 = .min

    init(localName: String? = nil) {
        self.localName = localName
    }

    init(_ bytes: [UInt8]) {
        var index = 0
        var shortName: String?
        while index < bytes.count {
            let length = Int(bytes[index])
            guard length > 0, index + length < bytes.count else { break }
            let type = bytes[index + 1]
            let value = Array(bytes[(index + 2)..<(index + 1 + length)])
            switch type {
            case 0x02, 0x03: serviceUUIDs += Self.uuids(value, size: 2)
            case 0x04, 0x05: serviceUUIDs += Self.uuids(value, size: 4)
            case 0x06, 0x07: serviceUUIDs += Self.uuids(value, size: 16)
            case 0x08: shortName = String(decoding: value, as: UTF8.self)
            case 0x09: localName = String(decoding: value, as: UTF8.self)
            case 0x0A where value.count == 1: txPowerLevel = Int32(Int8(bitPattern: value[0]))
            case 0x14: solicitedServiceUUIDs += Self.uuids(value, size: 2)
            case 0x1F: solicitedServiceUUIDs += Self.uuids(value, size: 4)
            case 0x15: solicitedServiceUUIDs += Self.uuids(value, size: 16)
            case 0x16: addServiceData(value, size: 2)
            case 0x20: addServiceData(value, size: 4)
            case 0x21: addServiceData(value, size: 16)
            case 0xFF where manufacturerData == nil: manufacturerData = value
            default: break
            }
            index += 1 + length
        }
        if localName == nil {
            localName = shortName
        }
    }

    private mutating func addServiceData(_ value: [UInt8], size: Int) {
        guard value.count >= size, let uuid = Self.uuids(Array(value[0..<size]), size: size).first else { return }
        serviceData.append((uuid, Array(value[size...])))
    }

    /// Little-endian UUIDs of `size` bytes, as 128-bit strings.
    static func uuids(_ bytes: [UInt8], size: Int) -> [String] {
        stride(from: 0, to: bytes.count - bytes.count % size, by: size).compactMap { start in
            let bigEndian = bytes[start..<start + size].reversed().map(hex).joined()
            switch size {
            case 2, 4: return BluetoothMapping.expand(bigEndian)
            default:
                let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { range in
                    String(bigEndian.dropFirst(range.lowerBound).prefix(range.count))
                }
                return parts.joined(separator: "-")
            }
        }
    }

    static func hex(_ byte: UInt8) -> String {
        let digits = Array("0123456789ABCDEF")
        return String([digits[Int(byte >> 4)], digits[Int(byte & 0xF)]])
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.localName == rhs.localName && lhs.manufacturerData == rhs.manufacturerData
            && lhs.serviceUUIDs == rhs.serviceUUIDs && lhs.solicitedServiceUUIDs == rhs.solicitedServiceUUIDs
            && lhs.txPowerLevel == rhs.txPowerLevel
            && lhs.serviceData.elementsEqual(rhs.serviceData) { $0.uuid == $1.uuid && $0.data == $1.data }
    }
}
