/// What the Bluetooth contracts ask Android, through the Kotlin
/// `org.pureswift.appruntime.contracts.BluetoothSystem` (`AndroidHostApp`
/// binds it): the adapter, `BluetoothLeScanner` and `BluetoothGatt`, whose
/// callbacks arrive on the main looper for `BluetoothHub`. UUIDs cross as
/// full 128-bit strings. Main thread only.
public protocol BluetoothSystem: AnyObject {

    /// `FEATURE_BLUETOOTH_LE`.
    func hasLowEnergy() -> Bool

    /// `BluetoothAdapter.getState()`: `STATE_OFF` 10 to `STATE_TURNING_OFF`
    /// 13; -1 without an adapter.
    func adapterState() -> Int32

    /// `ACTION_STATE_CHANGED`: changes go to `BluetoothHub.adapterStateChanged`.
    func setStateListening(_ on: Bool)

    /// Starts a scan for `central`, filtered by service UUIDs; false if
    /// Android refused at once. `mode` is a `ScanSettings.SCAN_MODE_*`.
    func startScan(central: Int64, services: [String], mode: Int32) -> Bool

    func stopScan(central: Int64)

    /// Bonded devices' addresses.
    func bondedAddresses() -> [String]

    /// Devices connected over GATT, by any app.
    func connectedAddresses() -> [String]

    /// A connection to `address`, whose callbacks carry `handle`.
    func makeConnection(handle: Int64, address: String) -> any GattConnection
}

/// One `BluetoothGatt`. Each operation returns false if Android refused it
/// at once; otherwise its callback follows. Characteristics are found by
/// their instance ID, descriptors by their characteristic's and their
/// UUID.
public protocol GattConnection: AnyObject {

    /// `connectGatt(…, TRANSPORT_LE, handler)` on the main looper.
    func connect() -> Bool

    func disconnect()

    /// Releases the `BluetoothGatt`.
    func close()

    func discoverServices() -> Bool

    /// The database after discovery (`GattItem`).
    func services() -> [GattItem]

    func requestMTU(_ mtu: Int32) -> Bool

    func readCharacteristic(_ id: Int32) -> Bool

    /// `writeType` is a `BluetoothGattCharacteristic.WRITE_TYPE_*`.
    func writeCharacteristic(_ id: Int32, value: [UInt8], writeType: Int32) -> Bool

    /// `setCharacteristicNotification`, which only changes what Android
    /// delivers; the CCCD write is separate.
    func setNotification(_ id: Int32, enabled: Bool) -> Bool

    func readDescriptor(characteristic: Int32, uuid: String) -> Bool

    func writeDescriptor(characteristic: Int32, uuid: String, value: [UInt8]) -> Bool

    func readRSSI() -> Bool

    /// The name Android has for the device, or "".
    func name() -> String
}

/// One attribute of a discovered database, in order: a service, then its
/// characteristics, each followed by its descriptors.
public struct GattItem: Equatable, Sendable {

    public enum Kind: Int32, Sendable {
        case service = 0
        case characteristic = 1
        case descriptor = 2
    }

    public var kind: Kind

    /// A service's or characteristic's instance ID; 0 for a descriptor.
    public var id: Int32

    /// A service's primary flag (1 or 0), or a characteristic's properties.
    public var flags: Int32

    /// A 128-bit UUID string.
    public var uuid: String

    public init(kind: Kind, id: Int32, flags: Int32, uuid: String) {
        self.kind = kind
        self.id = id
        self.flags = flags
        self.uuid = uuid
    }

    /// The Kotlin side's flat arrays: three numbers per item, and its UUID.
    public static func decode(numbers: [Int32], uuids: [String]) -> [GattItem] {
        guard numbers.count == uuids.count * 3 else { return [] }
        return uuids.indices.compactMap { index in
            GattItem.Kind(rawValue: numbers[index * 3]).map {
                GattItem(kind: $0, id: numbers[index * 3 + 1], flags: numbers[index * 3 + 2], uuid: uuids[index])
            }
        }
    }
}
