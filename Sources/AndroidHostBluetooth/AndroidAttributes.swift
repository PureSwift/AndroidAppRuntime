import AndroidHost
import DynamicBluetooth
import DynamicRuntime

/// The `Service` contract: a discovered `BluetoothGattService`.
public final class AndroidService: Service {

    /// The instance ID.
    let id: Int32

    let fullUUID: String

    let primary: Bool

    private(set) weak var owner: AndroidPeripheral?

    fileprivate(set) var children: [AndroidCharacteristic] = []

    init(id: Int32, uuid: String, primary: Bool, owner: AndroidPeripheral?) {
        self.id = id
        self.fullUUID = uuid.uppercased()
        self.primary = primary
        self.owner = owner
    }

    /// The tree for a discovered database, in its order.
    static func build(_ items: [GattItem], owner: AndroidPeripheral?) -> [AndroidService] {
        var services: [AndroidService] = []
        for item in items {
            switch item.kind {
            case .service:
                services.append(AndroidService(id: item.id, uuid: item.uuid, primary: item.flags != 0, owner: owner))
            case .characteristic:
                guard let service = services.last else { continue }
                service.children.append(AndroidCharacteristic(id: item.id, uuid: item.uuid, flags: item.flags, owner: service))
            case .descriptor:
                guard let characteristic = services.last?.children.last else { continue }
                characteristic.descriptorList.append(AndroidDescriptor(uuid: item.uuid, owner: characteristic))
            }
        }
        return services
    }

    public func uuid() throws(RuntimeError) -> BluetoothUUID {
        try BluetoothMapping.uuid(fullUUID)
    }

    public func isPrimary() -> Bool { primary }

    public func characteristics() -> [any Characteristic] { children }

    /// The peripheral, while its central keeps it.
    public func peripheral() -> any Peripheral {
        owner ?? AndroidPeripheral.orphan
    }
}

/// The `Characteristic` contract.
public final class AndroidCharacteristic: Characteristic {

    let id: Int32

    let fullUUID: String

    /// `PROPERTY_*`, which are the GATT properties.
    let flags: Int32

    private(set) weak var owner: AndroidService?

    var lastValue: [UInt8]?

    var notifying = false

    fileprivate(set) var descriptorList: [AndroidDescriptor] = []

    init(id: Int32, uuid: String, flags: Int32, owner: AndroidService?) {
        self.id = id
        self.fullUUID = uuid.uppercased()
        self.flags = flags
        self.owner = owner
    }

    public func uuid() throws(RuntimeError) -> BluetoothUUID {
        try BluetoothMapping.uuid(fullUUID)
    }

    public func properties() -> Int32 { flags & 0xFF }

    public func value() -> [UInt8]? { lastValue }

    public func isNotifying() -> Bool { notifying }

    public func descriptors() -> [any Descriptor] { descriptorList }

    public func service() -> any Service {
        owner ?? AndroidService(id: 0, uuid: fullUUID, primary: false, owner: nil)
    }
}

/// The `Descriptor` contract.
public final class AndroidDescriptor: Descriptor {

    let fullUUID: String

    private(set) weak var owner: AndroidCharacteristic?

    var lastValue: [UInt8]?

    /// A write's value until Android confirms it.
    var pending: [UInt8]?

    init(uuid: String, owner: AndroidCharacteristic?) {
        self.fullUUID = uuid.uppercased()
        self.owner = owner
    }

    public func uuid() throws(RuntimeError) -> BluetoothUUID {
        try BluetoothMapping.uuid(fullUUID)
    }

    public func value() -> [UInt8]? { lastValue }

    public func characteristic() -> any Characteristic {
        owner ?? AndroidCharacteristic(id: 0, uuid: fullUUID, flags: 0, owner: nil)
    }
}

/// The `Advertisement` contract: a scan record's AD structures.
public final class AndroidAdvertisement: Advertisement {

    let data: AdvertisementData

    /// `ScanResult.isConnectable` (API 26+): 1, 0, or -1 if unknown.
    let connectable: Int32

    init(_ data: AdvertisementData, connectable: Int32) {
        self.data = data
        self.connectable = connectable
    }

    public func localName() -> String? { data.localName }

    public func manufacturerData() -> [UInt8]? { data.manufacturerData }

    public func serviceUUIDs() throws(RuntimeError) -> [BluetoothUUID] {
        try uuids(data.serviceUUIDs)
    }

    public func serviceDataUUIDs() throws(RuntimeError) -> [BluetoothUUID] {
        try uuids(data.serviceData.map(\.uuid))
    }

    public func serviceData(_ uuid: BluetoothUUID) -> [UInt8]? {
        guard let full = BluetoothMapping.expand(uuid.rawValue) else { return nil }
        return data.serviceData.first { $0.uuid == full }?.data
    }

    public func solicitedServiceUUIDs() throws(RuntimeError) -> [BluetoothUUID] {
        try uuids(data.solicitedServiceUUIDs)
    }

    public func txPowerLevel() -> Int32 { data.txPowerLevel }

    public func isConnectable() -> Int32 { connectable }

    private func uuids(_ strings: [String]) throws(RuntimeError) -> [BluetoothUUID] {
        var uuids: [BluetoothUUID] = []
        for string in strings {
            uuids.append(try BluetoothMapping.uuid(string))
        }
        return uuids
    }
}

extension AndroidPeripheral {

    /// What an attribute returns once its peripheral is gone: the contract
    /// has no nil for it.
    nonisolated(unsafe) static let orphan = AndroidPeripheral(address: "00:00:00:00:00:00", central: nil)
}

/// The Bluetooth contracts (`Plan.md` §6.2): the central role. The
/// `bluetooth` capability's permissions come from `AndroidPermissions`'
/// table.
public enum AndroidHostBluetooth: HostModule {

    public static var contracts: [ContractDescriptor] {
        [
            CentralProxy.descriptor, CentralDelegateProxy.descriptor, PeripheralProxy.descriptor,
            PeripheralDelegateProxy.descriptor, ServiceProxy.descriptor, CharacteristicProxy.descriptor,
            DescriptorProxy.descriptor, AdvertisementProxy.descriptor,
        ]
    }

    public static func register(in registrar: some ContractRegistrar) {
        CentralProxy.register(AndroidCentral.self, in: registrar)
        CentralDelegateProxy.registerInterface(in: registrar)
        PeripheralProxy.register(AndroidPeripheral.self, in: registrar)
        PeripheralDelegateProxy.registerInterface(in: registrar)
        ServiceProxy.register(AndroidService.self, in: registrar)
        CharacteristicProxy.register(AndroidCharacteristic.self, in: registrar)
        DescriptorProxy.register(AndroidDescriptor.self, in: registrar)
        AdvertisementProxy.register(AndroidAdvertisement.self, in: registrar)
    }
}
