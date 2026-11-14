import AndroidHost
import DynamicBluetooth
import DynamicRuntime

/// The `Central` contract over `BluetoothLeScanner` and `BluetoothGatt`
/// (`Plan.md` §6.2), on the main looper.
///
/// - **Authorization** is the `bluetooth` capability's runtime permissions:
///   `BLUETOOTH_SCAN` and `BLUETOOTH_CONNECT` on API 31+, fine location
///   before.
/// - **Scans** without duplicates report each peripheral once per scan.
///   Android allows five starts in 30 seconds and then silently finds
///   nothing, so the sixth reports `scanThrottled` instead.
/// - **Peripherals** are one object per address for the central, and their
///   identifier is the address.
public final class AndroidCentral: Central {

    let hub: BluetoothHub

    let handle: Int64

    /// Kept strongly (`Plan.md` §6).
    let delegate: any CentralDelegate

    private(set) var scanning = false

    private var allowDuplicates = false

    private var seen: Set<String> = []

    private var scanStarts: [Int64] = []

    /// Every peripheral this central handed out, by address.
    private(set) var peripherals: [String: AndroidPeripheral] = [:]

    private var lastAuthorization: BluetoothAuthorization?

    private var lastState: CentralState?

    init(delegate: any CentralDelegate, hub: BluetoothHub = .shared) {
        self.delegate = delegate
        self.hub = hub
        self.handle = hub.nextHandle()
        hub.register(self)
    }

    deinit {
        if scanning {
            hub.system.stopScan(central: handle)
        }
        for peripheral in peripherals.values {
            peripheral.release()
        }
        hub.remove(handle)
    }

    public static func authorizationStatus() -> Int32 {
        BluetoothHub.shared.authorization.rawValue
    }

    /// Reports the state soon after, as CoreBluetooth does.
    public static func make(_ delegate: any CentralDelegate) -> AndroidCentral {
        let central = AndroidCentral(delegate: delegate)
        MainLooper.shared.post { [weak central] in
            central?.update()
        }
        return central
    }

    public func requestAuthorization() {
        guard hub.authorization == .notDetermined || hub.authorization == .denied else {
            update()
            return
        }
        hub.requestAuthorization()
    }

    public func state() -> Int32 {
        hub.state.rawValue
    }

    /// Tells the delegate what changed; a scan stops when the central
    /// can't run.
    func update() {
        let authorization = hub.authorization
        if authorization != lastAuthorization {
            lastAuthorization = authorization
            delegate.didChangeAuthorization(self, status: authorization.rawValue)
        }
        let state = hub.state
        guard state != lastState else { return }
        lastState = state
        delegate.didUpdateState(self, state: state.rawValue)
        if state != .poweredOn {
            if scanning {
                scanning = false
                hub.system.stopScan(central: handle)
                delegate.didStopScanning(self, error: (BluetoothMapping.error(for: state) ?? .unknown).rawValue)
            }
            for peripheral in peripherals.values where peripheral.connection != nil {
                peripheral.adapterTurnedOff()
            }
        }
    }

    // MARK: Scanning

    public func scan(services: [BluetoothUUID], allowDuplicates: Bool, mode: Int32) {
        if let error = BluetoothMapping.error(for: hub.state) {
            delegate.didStopScanning(self, error: error.rawValue)
            return
        }
        if scanning {
            hub.system.stopScan(central: handle)
            scanning = false
        }
        let now = MainLooper.now()
        guard !BluetoothMapping.isThrottled(scanStarts, now: now) else {
            delegate.didStopScanning(self, error: BluetoothError.scanThrottled.rawValue)
            return
        }
        scanStarts = scanStarts.filter { now - $0 < BluetoothMapping.scanStartWindow } + [now]
        self.allowDuplicates = allowDuplicates
        seen = []
        let filter = services.compactMap { BluetoothMapping.expand($0.rawValue) }
        guard hub.system.startScan(central: handle, services: filter, mode: BluetoothMapping.scanMode(mode)) else {
            delegate.didStopScanning(self, error: BluetoothError.scanFailed.rawValue)
            return
        }
        scanning = true
    }

    public func stopScan() {
        guard scanning else { return }
        scanning = false
        hub.system.stopScan(central: handle)
    }

    public func isScanning() -> Bool {
        scanning
    }

    /// A `ScanResult`.
    func discovered(address: String, name: String, rssi: Int32, connectable: Int32, record: [UInt8]) {
        guard scanning else { return }
        if !allowDuplicates {
            guard seen.insert(address).inserted else { return }
        }
        let peripheral = self.peripheral(address)
        if !name.isEmpty, peripheral.knownName != name {
            peripheral.knownName = name
        }
        var data = AdvertisementData(record)
        if data.localName == nil, !name.isEmpty {
            data.localName = name
        }
        delegate.didDiscover(self, peripheral: peripheral, advertisement: AndroidAdvertisement(data, connectable: connectable), rssi: rssi)
    }

    func scanFailed(code: Int32) {
        guard scanning else { return }
        scanning = false
        delegate.didStopScanning(self, error: BluetoothMapping.scanError(code).rawValue)
    }

    // MARK: Peripherals

    /// The one object for `address`.
    func peripheral(_ address: String) -> AndroidPeripheral {
        if let peripheral = peripherals[address] {
            return peripheral
        }
        let peripheral = AndroidPeripheral(address: address, central: self)
        peripherals[address] = peripheral
        hub.known.insert(address)
        return peripheral
    }

    public func connect(_ peripheral: any Peripheral, timeout: Int32) {
        guard let peripheral = own(peripheral) else {
            HostLog.error("Central.connect: a peripheral from another central")
            return
        }
        if let error = BluetoothMapping.error(for: hub.state) {
            delegate.didFailToConnect(self, peripheral: peripheral, error: error.rawValue)
            return
        }
        peripheral.connect(timeout: timeout)
    }

    public func cancelConnection(_ peripheral: any Peripheral) {
        own(peripheral)?.cancelConnection()
    }

    private func own(_ peripheral: any Peripheral) -> AndroidPeripheral? {
        guard let peripheral = HostObjects.own(peripheral, as: AndroidPeripheral.self), peripheral.central === self else { return nil }
        return peripheral
    }

    /// Addresses this process saw or the system bonded.
    public func retrievePeripherals(_ identifiers: [String]) -> [any Peripheral] {
        let bonded = Set(hub.system.bondedAddresses())
        return identifiers.compactMap { identifier in
            let address = identifier.uppercased()
            guard hub.known.contains(address) || bonded.contains(address) else { return nil }
            return peripheral(address)
        }
    }

    /// Every device connected over GATT: Android can't tell their services
    /// without connecting, so `services` doesn't filter them.
    public func retrieveConnectedPeripherals(_ services: [BluetoothUUID]) -> [any Peripheral] {
        hub.system.connectedAddresses().map { peripheral($0.uppercased()) }
    }

    // Delegate calls for peripherals.

    func didConnect(_ peripheral: AndroidPeripheral) {
        delegate.didConnect(self, peripheral: peripheral)
    }

    func didFailToConnect(_ peripheral: AndroidPeripheral, error: BluetoothError) {
        delegate.didFailToConnect(self, peripheral: peripheral, error: error.rawValue)
    }

    func didDisconnect(_ peripheral: AndroidPeripheral, error: Int32) {
        delegate.didDisconnect(self, peripheral: peripheral, error: error)
    }
}

/// Every central and connection, by handle, and what they share. Main
/// thread only.
public final class BluetoothHub {

    nonisolated(unsafe) public static let shared = BluetoothHub()

    /// Makes the system on first use; `AndroidHostApp` sets it.
    public var makeSystem: (() -> any BluetoothSystem)?

    private var _system: (any BluetoothSystem)?

    public var system: any BluetoothSystem {
        if let _system {
            return _system
        }
        guard let makeSystem else {
            fatalError("BluetoothHub.makeSystem isn't set")
        }
        let system = makeSystem()
        _system = system
        return system
    }

    private var centrals: [Int64: WeakCentral] = [:]

    private var connections: [Int64: WeakPeripheral] = [:]

    private var lastHandle: Int64 = 0

    private var listening = false

    /// Addresses seen in this process, for `retrievePeripherals`.
    var known: Set<String> = []

    public init() { }

    /// Replaces the system, for tests.
    public func use(_ system: (any BluetoothSystem)?) {
        _system = system
        centrals = [:]
        connections = [:]
        known = []
        listening = false
    }

    func nextHandle() -> Int64 {
        lastHandle += 1
        return lastHandle
    }

    func register(_ central: AndroidCentral) {
        centrals[central.handle] = WeakCentral(central: central)
        updateListening()
    }

    func remove(_ handle: Int64) {
        centrals[handle] = nil
        updateListening()
    }

    func add(_ peripheral: AndroidPeripheral) -> Int64 {
        let handle = nextHandle()
        connections[handle] = WeakPeripheral(peripheral: peripheral)
        return handle
    }

    func removeConnection(_ handle: Int64) {
        connections[handle] = nil
    }

    /// The adapter's broadcasts, while any central lives.
    private func updateListening() {
        let wanted = centrals.values.contains { $0.central != nil }
        guard wanted != listening, _system != nil || makeSystem != nil else { return }
        listening = wanted
        system.setStateListening(wanted)
    }

    // MARK: Authorization and state

    /// The bluetooth capability's permissions, without its hardware
    /// feature: a device without Bluetooth LE is `unsupported`, not
    /// unauthorized.
    var requirement: AndroidPermissions.Requirement {
        var requirement = AndroidPermissions.requirement(.bluetooth, api: AndroidPermissions.system?.apiLevel ?? 31)!
        requirement.feature = nil
        return requirement
    }

    var authorization: BluetoothAuthorization {
        guard let permissions = AndroidPermissions.system else { return .denied }
        return BluetoothMapping.authorization(AndroidPermissions.status(requirement, system: permissions))
    }

    var state: CentralState {
        BluetoothMapping.state(hasLowEnergy: system.hasLowEnergy(), authorization: authorization, adapter: system.adapterState())
    }

    func requestAuthorization() {
        AndroidPermissions.request(requirement.permissions) { [self] _ in
            updateAll()
        }
    }

    /// After a request, when the adapter changes, and when the app becomes
    /// active.
    public func updateAll() {
        for central in centrals.values.compactMap(\.central) {
            central.update()
        }
    }

    // MARK: Events

    public func adapterStateChanged() {
        updateAll()
    }

    public func scanResult(central: Int64, address: String, name: String, rssi: Int32, connectable: Int32, record: [UInt8]) {
        centrals[central]?.central?.discovered(address: address.uppercased(), name: name, rssi: rssi, connectable: connectable, record: record)
    }

    public func scanFailed(central: Int64, code: Int32) {
        centrals[central]?.central?.scanFailed(code: code)
    }

    func connection(_ handle: Int64) -> AndroidPeripheral? {
        connections[handle]?.peripheral
    }

    public func connectionStateChanged(handle: Int64, status: Int32, connected: Bool) {
        connection(handle)?.connectionChanged(status: status, connected: connected)
    }

    public func servicesDiscovered(handle: Int64, status: Int32) {
        connection(handle)?.servicesDiscovered(status: status)
    }

    public func mtuChanged(handle: Int64, mtu: Int32, status: Int32) {
        connection(handle)?.mtuChanged(mtu, status: status)
    }

    public func characteristicRead(handle: Int64, id: Int32, value: [UInt8], status: Int32) {
        connection(handle)?.characteristicRead(id, value: value, status: status)
    }

    public func characteristicWritten(handle: Int64, id: Int32, status: Int32) {
        connection(handle)?.characteristicWritten(id, status: status)
    }

    public func characteristicChanged(handle: Int64, id: Int32, value: [UInt8]) {
        connection(handle)?.characteristicChanged(id, value: value)
    }

    public func descriptorRead(handle: Int64, characteristic: Int32, uuid: String, value: [UInt8], status: Int32) {
        connection(handle)?.descriptorRead(characteristic: characteristic, uuid: uuid, value: value, status: status)
    }

    public func descriptorWritten(handle: Int64, characteristic: Int32, uuid: String, status: Int32) {
        connection(handle)?.descriptorWritten(characteristic: characteristic, uuid: uuid, status: status)
    }

    public func rssiRead(handle: Int64, rssi: Int32, status: Int32) {
        connection(handle)?.rssiRead(rssi, status: status)
    }

    public func servicesChanged(handle: Int64) {
        connection(handle)?.servicesChanged()
    }
}

private struct WeakCentral {
    weak var central: AndroidCentral?
}

private struct WeakPeripheral {
    weak var peripheral: AndroidPeripheral?
}
