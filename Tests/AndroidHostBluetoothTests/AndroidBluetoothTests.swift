import AndroidHost
@testable import AndroidHostBluetooth
import DynamicBluetooth
import DynamicRuntime
import Testing

/// Bluetooth permissions, granted unless a test says otherwise.
final class FakePermissions: PermissionSystem {
    var apiLevel: Int32 = 34
    var granted: Set<String> = ["android.permission.BLUETOOTH_SCAN", "android.permission.BLUETOOTH_CONNECT"]
    var requests: [[String]] = []
    func isGranted(_ permission: String) -> Bool { granted.contains(permission) }
    func wasRequested(_ permission: String) -> Bool { false }
    func isDeclared(_ permission: String) -> Bool { true }
    func hasFeature(_ feature: String) -> Bool { true }
    func request(_ permissions: [String], id: Int32) -> Bool {
        requests.append(permissions)
        return true
    }
}

/// An adapter and connections the tests drive.
final class FakeBluetoothSystem: BluetoothSystem {

    final class Connection: GattConnection {
        var calls: [String] = []
        var refuse: Set<String> = []
        var items: [GattItem] = []

        func record(_ call: String) -> Bool {
            calls.append(call)
            return !refuse.contains(call.split(separator: " ").first.map(String.init) ?? call)
        }

        func connect() -> Bool { record("connect") }
        func disconnect() { calls.append("disconnect") }
        func close() { calls.append("close") }
        func discoverServices() -> Bool { record("discover") }
        func services() -> [GattItem] { items }
        func requestMTU(_ mtu: Int32) -> Bool { record("mtu \(mtu)") }
        func readCharacteristic(_ id: Int32) -> Bool { record("read \(id)") }
        func writeCharacteristic(_ id: Int32, value: [UInt8], writeType: Int32) -> Bool { record("write \(id) \(value) \(writeType)") }
        func setNotification(_ id: Int32, enabled: Bool) -> Bool { record("notification \(id) \(enabled)") }
        func readDescriptor(characteristic: Int32, uuid: String) -> Bool { record("readDescriptor \(characteristic) \(uuid.prefix(8))") }
        func writeDescriptor(characteristic: Int32, uuid: String, value: [UInt8]) -> Bool { record("writeDescriptor \(characteristic) \(uuid.prefix(8)) \(value)") }
        func readRSSI() -> Bool { record("rssi") }
        func name() -> String { "" }
    }

    var lowEnergy = true
    var adapter: Int32 = 12
    var listening = false
    var scans: [(Int64, [String], Int32)] = []
    var stopped: [Int64] = []
    var bonded: [String] = []
    var connected: [String] = []
    var connections: [Int64: Connection] = [:]

    func hasLowEnergy() -> Bool { lowEnergy }
    func adapterState() -> Int32 { adapter }
    func setStateListening(_ on: Bool) { listening = on }

    func startScan(central: Int64, services: [String], mode: Int32) -> Bool {
        scans.append((central, services, mode))
        return true
    }

    func stopScan(central: Int64) { stopped.append(central) }
    func bondedAddresses() -> [String] { bonded }
    func connectedAddresses() -> [String] { connected }

    func makeConnection(handle: Int64, address: String) -> any GattConnection {
        let connection = Connection()
        connections[handle] = connection
        return connection
    }
}

final class RecordingCentralDelegate: BluetoothCentralDelegate {
    var events: [String] = []
    var discovered: [(any BluetoothPeripheral, any BluetoothAdvertisement)] = []

    func didChangeAuthorization(_ central: any BluetoothCentral, status: Int32) { events.append("authorization \(status)") }
    func didUpdateState(_ central: any BluetoothCentral, state: Int32) { events.append("state \(state)") }
    func didDiscover(_ central: any BluetoothCentral, peripheral: any BluetoothPeripheral, advertisement: any BluetoothAdvertisement, rssi: Int32) {
        events.append("discover \(peripheral.identifier()) \(rssi)")
        discovered.append((peripheral, advertisement))
    }
    func didStopScanning(_ central: any BluetoothCentral, error: Int32) { events.append("stop \(error)") }
    func didConnect(_ central: any BluetoothCentral, peripheral: any BluetoothPeripheral) { events.append("connect") }
    func didFailToConnect(_ central: any BluetoothCentral, peripheral: any BluetoothPeripheral, error: Int32) { events.append("fail \(error)") }
    func didDisconnect(_ central: any BluetoothCentral, peripheral: any BluetoothPeripheral, error: Int32) { events.append("disconnect \(error)") }
}

final class RecordingPeripheralDelegate: BluetoothPeripheralDelegate {
    var events: [String] = []

    func didDiscoverServices(_ peripheral: any BluetoothPeripheral, error: Int32) { events.append("services \(error)") }
    func didDiscoverCharacteristics(_ peripheral: any BluetoothPeripheral, service: any BluetoothService, error: Int32) { events.append("characteristics \(error)") }
    func didDiscoverDescriptors(_ peripheral: any BluetoothPeripheral, characteristic: any BluetoothCharacteristic, error: Int32) { events.append("descriptors \(error)") }
    func didUpdateValue(_ peripheral: any BluetoothPeripheral, characteristic: any BluetoothCharacteristic, value: [UInt8], error: Int32) { events.append("value \(value) \(error)") }
    func didWriteValue(_ peripheral: any BluetoothPeripheral, characteristic: any BluetoothCharacteristic, error: Int32) { events.append("wrote \(error)") }
    func didUpdateNotificationState(_ peripheral: any BluetoothPeripheral, characteristic: any BluetoothCharacteristic, error: Int32) { events.append("notifying \(characteristic.isNotifying()) \(error)") }
    func didUpdateDescriptorValue(_ peripheral: any BluetoothPeripheral, descriptor: any BluetoothDescriptor, value: [UInt8], error: Int32) { events.append("descriptor \(value) \(error)") }
    func didWriteDescriptorValue(_ peripheral: any BluetoothPeripheral, descriptor: any BluetoothDescriptor, error: Int32) { events.append("wroteDescriptor \(error)") }
    func didReadRSSI(_ peripheral: any BluetoothPeripheral, rssi: Int32, error: Int32) { events.append("rssi \(rssi) \(error)") }
    func isReadyToSendWriteWithoutResponse(_ peripheral: any BluetoothPeripheral) { events.append("ready") }
    func didModifyServices(_ peripheral: any BluetoothPeripheral) { events.append("modified") }
    func didUpdateName(_ peripheral: any BluetoothPeripheral) { events.append("name") }
}

/// Serialized: the hub and `AndroidPermissions` are shared.
@Suite(.serialized) struct AndroidBluetoothTests {

    let system = FakeBluetoothSystem()
    let permissions = FakePermissions()
    let hub = BluetoothHub.shared

    init() {
        AndroidPermissions.reset()
        AndroidPermissions.system = permissions
        hub.use(system)
    }

    static let heartRate = "0000180D" + BluetoothMapping.baseSuffix
    static let measurement = "00002A37" + BluetoothMapping.baseSuffix

    /// A central with a connected peripheral whose database has a heart
    /// rate service with one notifying characteristic and its CCCD.
    func connected(_ delegate: RecordingCentralDelegate = RecordingCentralDelegate()) -> (AndroidCentral, AndroidPeripheral, FakeBluetoothSystem.Connection) {
        let central = AndroidCentral(delegate: delegate)
        let peripheral = central.peripheral("AA:BB:CC:DD:EE:FF")
        central.connect(peripheral, timeout: 0)
        let (handle, connection) = system.connections.first!
        connection.items = [
            GattItem(kind: .service, id: 10, flags: 1, uuid: Self.heartRate),
            GattItem(kind: .characteristic, id: 11, flags: 0x12, uuid: Self.measurement),
            GattItem(kind: .descriptor, id: 0, flags: 0, uuid: BluetoothMapping.cccd),
        ]
        hub.connectionStateChanged(handle: handle, status: 0, connected: true)
        hub.mtuChanged(handle: handle, mtu: 247, status: 0)
        return (central, peripheral, connection)
    }

    // MARK: Mappings

    @Test func convertsUUIDs() throws {
        #expect(BluetoothMapping.expand("180d") == Self.heartRate)
        #expect(BluetoothMapping.expand("0000180D") == Self.heartRate)
        #expect(BluetoothMapping.expand("xyz") == nil)
        #expect(BluetoothMapping.shorten(Self.heartRate.lowercased()) == "180D")
        #expect(BluetoothMapping.shorten("1234ABCD" + BluetoothMapping.baseSuffix) == "1234ABCD")
        let custom = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
        #expect(BluetoothMapping.shorten(custom) == custom)
        #expect(try BluetoothMapping.uuid(Self.heartRate) == .bit16(0x180D))
    }

    @Test func parsesAdvertisements() {
        let record: [UInt8] = [
            0x02, 0x01, 0x06,                         // flags
            0x05, 0x03, 0x0D, 0x18, 0x0F, 0x18,       // 16-bit services 180D, 180F
            0x05, 0x09, 0x41, 0x64, 0x61, 0x21,       // complete name "Ada!"
            0x02, 0x0A, 0xF4,                         // tx power -12
            0x05, 0xFF, 0x4C, 0x00, 0x01, 0x02,       // Apple manufacturer data
            0x04, 0x16, 0x0F, 0x18, 0x64,             // battery service data 100
            0x11, 0x07, 0x9E, 0xCA, 0xDC, 0x24, 0x0E, 0xE5, 0xA9, 0xE0, 0x93, 0xF3, 0xA3, 0xB5, 0x01, 0x00, 0x40, 0x6E,
            0x00,
        ]
        let data = AdvertisementData(record)
        #expect(data.localName == "Ada!")
        #expect(data.txPowerLevel == -12)
        #expect(data.manufacturerData == [0x4C, 0x00, 0x01, 0x02])
        #expect(data.serviceUUIDs == [Self.heartRate, "0000180F" + BluetoothMapping.baseSuffix, "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"])
        #expect(data.serviceData.first?.data == [0x64])
        let advertisement = AndroidAdvertisement(data, connectable: 1)
        #expect(advertisement.serviceData(.bit16(0x180F)) == [0x64])
        #expect(advertisement.companyIdentifier?.rawValue == 0x004C)
        // A truncated structure ends the parse without trapping.
        #expect(AdvertisementData([0x09, 0x09, 0x41]).localName == nil)
        #expect(AdvertisementData([0x02, 0x08, 0x42]).localName == "B", "the shortened name when there's no complete one")
    }

    @Test func mapsStatesAndErrors() {
        #expect(BluetoothMapping.state(hasLowEnergy: false, authorization: .allowed, adapter: 12) == .unsupported)
        #expect(BluetoothMapping.state(hasLowEnergy: true, authorization: .denied, adapter: 12) == .unauthorized)
        #expect(BluetoothMapping.state(hasLowEnergy: true, authorization: .allowed, adapter: 10) == .poweredOff)
        #expect(BluetoothMapping.state(hasLowEnergy: true, authorization: .allowed, adapter: 11) == .resetting)
        #expect(BluetoothMapping.state(hasLowEnergy: true, authorization: .allowed, adapter: 12) == .poweredOn)
        #expect(BluetoothMapping.operationError(0) == 0)
        #expect(BluetoothMapping.operationError(5) == BluetoothError.attribute.rawValue + 5)
        #expect(BluetoothError(code: BluetoothMapping.operationError(0x0F)) == .insufficientAuthentication)
        #expect(BluetoothMapping.operationError(133) == BluetoothError.unknown.rawValue)
        #expect(BluetoothMapping.disconnectError(status: 19, requested: false) == BluetoothError.peripheralDisconnected.rawValue)
        #expect(BluetoothMapping.disconnectError(status: 8, requested: false) == BluetoothError.connectionTimeout.rawValue)
        #expect(BluetoothMapping.disconnectError(status: 19, requested: true) == 0)
        #expect(BluetoothMapping.connectError(status: 133) == .connectionFailed)
        #expect(BluetoothMapping.scanError(6) == .scanThrottled)
        #expect(BluetoothMapping.cccdValue(enabled: true, properties: 0x10) == [1, 0])
        #expect(BluetoothMapping.cccdValue(enabled: true, properties: 0x20) == [2, 0])
        #expect(BluetoothMapping.cccdValue(enabled: false, properties: 0x10) == [0, 0])
        #expect(GattItem.decode(numbers: [0, 1, 1, 1, 2, 0x10], uuids: ["a", "b"]).map(\.kind) == [.service, .characteristic])
        #expect(GattItem.decode(numbers: [0, 1], uuids: ["a"]).isEmpty)
    }

    // MARK: Central

    @Test func reportsAuthorizationAndState() {
        permissions.granted = []
        let delegate = RecordingCentralDelegate()
        let central = AndroidCentral(delegate: delegate)
        central.update()
        #expect(delegate.events == ["authorization 0", "state 3"])
        #expect(system.listening, "a central listens to the adapter")
        central.requestAuthorization()
        #expect(permissions.requests == [["android.permission.BLUETOOTH_SCAN", "android.permission.BLUETOOTH_CONNECT"]])
        permissions.granted = ["android.permission.BLUETOOTH_SCAN", "android.permission.BLUETOOTH_CONNECT"]
        AndroidPermissions.didRequest(id: 1, permissions: [], granted: [])
        #expect(delegate.events == ["authorization 0", "state 3", "authorization 3", "state 5"])
        permissions.apiLevel = 30
        #expect(hub.requirement.permissions == [AndroidPermissions.fineLocation])
    }

    @Test func scans() throws {
        let delegate = RecordingCentralDelegate()
        let central = AndroidCentral(delegate: delegate)
        central.scan(services: [.bit16(0x180D)], allowDuplicates: false, mode: ScanMode.lowLatency.rawValue)
        #expect(central.isScanning())
        let scan = try #require(system.scans.first)
        #expect(scan.1 == [Self.heartRate])
        #expect(scan.2 == 2)
        hub.scanResult(central: central.handle, address: "aa:bb:cc:dd:ee:ff", name: "Strap", rssi: -60, connectable: 1, record: [])
        hub.scanResult(central: central.handle, address: "AA:BB:CC:DD:EE:FF", name: "Strap", rssi: -61, connectable: 1, record: [])
        #expect(delegate.events == ["discover AA:BB:CC:DD:EE:FF -60"], "no duplicates")
        #expect(delegate.discovered[0].1.localName() == "Strap", "the device's name when the record has none")
        #expect(delegate.discovered[0].0.name() == "Strap")
        #expect(central.retrievePeripherals(["aa:bb:cc:dd:ee:ff", "11:22:33:44:55:66"]).count == 1)
        #expect(central.retrievePeripherals(["AA:BB:CC:DD:EE:FF"])[0] === delegate.discovered[0].0, "one object per address")
        hub.scanFailed(central: central.handle, code: 2)
        #expect(delegate.events.last == "stop \(BluetoothError.scanFailed.rawValue)")
        #expect(!central.isScanning())
    }

    @Test func throttlesScanStarts() {
        let delegate = RecordingCentralDelegate()
        let central = AndroidCentral(delegate: delegate)
        for _ in 0..<BluetoothMapping.scanStartLimit {
            central.scan(services: [], allowDuplicates: true, mode: 0)
        }
        #expect(system.scans.count == BluetoothMapping.scanStartLimit)
        central.scan(services: [], allowDuplicates: true, mode: 0)
        #expect(delegate.events == ["stop \(BluetoothError.scanThrottled.rawValue)"])
        #expect(system.scans.count == BluetoothMapping.scanStartLimit)
    }

    @Test func failsWhenOff() {
        system.adapter = 10
        let delegate = RecordingCentralDelegate()
        let central = AndroidCentral(delegate: delegate)
        central.scan(services: [], allowDuplicates: false, mode: 0)
        central.connect(central.peripheral("AA:BB:CC:DD:EE:FF"), timeout: 0)
        #expect(delegate.events == ["stop \(BluetoothError.poweredOff.rawValue)", "fail \(BluetoothError.poweredOff.rawValue)"])
    }

    // MARK: Connections

    @Test func connectsAfterTheMTU() throws {
        let delegate = RecordingCentralDelegate()
        let (central, peripheral, connection) = connected(delegate)
        defer { withExtendedLifetime(central) {} }
        #expect(connection.calls == ["connect", "mtu 517"])
        #expect(delegate.events == ["connect"])
        #expect(peripheral.state() == PeripheralState.connected.rawValue)
        #expect(peripheral.maximumWriteLength(WriteType.withoutResponse.rawValue) == 244)
        #expect(peripheral.maximumWriteLength(WriteType.withResponse.rawValue) == 512)
    }

    @Test func failsToConnect() throws {
        let delegate = RecordingCentralDelegate()
        let central = AndroidCentral(delegate: delegate)
        central.connect(central.peripheral("AA:BB:CC:DD:EE:FF"), timeout: 0)
        let (handle, connection) = try #require(system.connections.first)
        hub.connectionStateChanged(handle: handle, status: 133, connected: false)
        #expect(delegate.events == ["fail \(BluetoothError.connectionFailed.rawValue)"])
        #expect(connection.calls.suffix(2) == ["disconnect", "close"])
    }

    @Test func queuesOperationsOneAtATime() throws {
        let (central, peripheral, connection) = connected()
        defer { withExtendedLifetime(central) {} }
        let delegate = RecordingPeripheralDelegate()
        peripheral.setDelegate(delegate)
        peripheral.discoverServices([])
        peripheral.readRSSI()
        #expect(connection.calls.suffix(1) == ["discover"], "the RSSI read waits")
        let handle = system.connections.keys.first!
        hub.servicesDiscovered(handle: handle, status: 0)
        #expect(connection.calls.last == "rssi")
        let service = try #require(peripheral.services().first)
        #expect(try service.uuid() == .bit16(0x180D))
        let characteristic = try #require(service.characteristics().first as? AndroidCharacteristic)
        #expect(characteristic.properties() == 0x12)
        #expect(characteristic.descriptors().count == 1)
        peripheral.readValue(characteristic)
        peripheral.setNotifyValue(true, for: characteristic)
        hub.rssiRead(handle: handle, rssi: -50, status: 0)
        hub.characteristicRead(handle: handle, id: 11, value: [1, 72], status: 0)
        #expect(connection.calls.suffix(2) == ["notification 11 true", "writeDescriptor 11 00002902 [1, 0]"])
        hub.descriptorWritten(handle: handle, characteristic: 11, uuid: BluetoothMapping.cccd, status: 0)
        hub.characteristicChanged(handle: handle, id: 11, value: [1, 80])
        #expect(delegate.events == ["services 0", "rssi -50 0", "value [1, 72] 0", "notifying true 0", "value [1, 80] 0"])
        #expect(characteristic.value() == [1, 80])
    }

    @Test func reportsATTErrorsAndRefusals() throws {
        let (central, peripheral, connection) = connected()
        defer { withExtendedLifetime(central) {} }
        let delegate = RecordingPeripheralDelegate()
        peripheral.setDelegate(delegate)
        peripheral.discoverServices([])
        let handle = system.connections.keys.first!
        hub.servicesDiscovered(handle: handle, status: 0)
        let characteristic = try #require(peripheral.services().first?.characteristics().first)
        peripheral.writeValue([9], for: characteristic, type: WriteType.withResponse.rawValue)
        hub.characteristicWritten(handle: handle, id: 11, status: 0x03)
        connection.refuse = ["read"]
        peripheral.readValue(characteristic)
        #expect(delegate.events.suffix(2) == ["wrote \(BluetoothError.attribute.rawValue + 3)", "value [] \(BluetoothError.unknown.rawValue)"])
    }

    @Test func failsEverythingPendingOnDisconnect() throws {
        let centralDelegate = RecordingCentralDelegate()
        let (central, peripheral, _) = connected(centralDelegate)
        let delegate = RecordingPeripheralDelegate()
        peripheral.setDelegate(delegate)
        peripheral.discoverServices([])
        peripheral.readRSSI()
        let handle = system.connections.keys.first!
        hub.connectionStateChanged(handle: handle, status: 19, connected: false)
        let notConnected = BluetoothError.notConnected.rawValue
        #expect(delegate.events == ["services \(notConnected)", "rssi 0 \(notConnected)"])
        #expect(centralDelegate.events.last == "disconnect \(BluetoothError.peripheralDisconnected.rawValue)")
        // Calls after the disconnect fail at once, each with its callback.
        peripheral.readRSSI()
        #expect(delegate.events.last == "rssi 0 \(notConnected)")
        // A cancelled connection reports no error.
        central.connect(peripheral, timeout: 0)
        let next = system.connections.keys.max()!
        hub.connectionStateChanged(handle: next, status: 0, connected: true)
        hub.mtuChanged(handle: next, mtu: 23, status: 0)
        central.cancelConnection(peripheral)
        hub.connectionStateChanged(handle: next, status: 0, connected: false)
        #expect(centralDelegate.events.suffix(2) == ["connect", "disconnect 0"])
    }

    @Test func pacesWritesWithoutResponse() throws {
        let (central, peripheral, _) = connected()
        defer { withExtendedLifetime(central) {} }
        let delegate = RecordingPeripheralDelegate()
        peripheral.setDelegate(delegate)
        peripheral.discoverServices([])
        let handle = system.connections.keys.first!
        hub.servicesDiscovered(handle: handle, status: 0)
        let characteristic = try #require(peripheral.services().first?.characteristics().first)
        #expect(peripheral.canSendWriteWithoutResponse())
        peripheral.writeValue([1], for: characteristic, type: WriteType.withoutResponse.rawValue)
        #expect(!peripheral.canSendWriteWithoutResponse())
        hub.characteristicWritten(handle: handle, id: 11, status: 0)
        #expect(delegate.events.last == "ready")
        #expect(peripheral.canSendWriteWithoutResponse())
    }

    @Test func registersEveryContract() {
        #expect(AndroidHostBluetooth.contracts.count == 8)
    }
}
