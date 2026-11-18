import AndroidHost
import DynamicBluetooth
import DynamicRuntime

/// The `BluetoothPeripheral` contract over one `BluetoothGatt`.
///
/// Android runs one GATT operation at a time, so the peripheral queues
/// them, and every call gets exactly one delegate callback, also when the
/// connection goes (`notConnected`). On connecting it asks for the largest
/// MTU before telling the central, so writes can be long from the start.
/// While connected it holds the host's foreground service, which runs for
/// apps that declare Bluetooth in the background (`HostBackground`).
public final class AndroidPeripheral: BluetoothPeripheral {

    let address: String

    private(set) weak var central: AndroidCentral?

    private(set) var delegate: (any BluetoothPeripheralDelegate)?

    var knownName: String?

    private(set) var peripheralState = PeripheralState.disconnected

    /// The connection, while there is one.
    private(set) var connection: (any GattConnection)?

    private var handle: Int64?

    private var cancelRequested = false

    private var timeout: TimerQueue.Token?

    private(set) var mtu: Int32 = 23

    private(set) var discovered: [AndroidService] = []

    /// One GATT operation at a time.
    private var queue: [Operation] = []

    private var running: Operation?

    private var writesWithoutResponse = 0

    private var owesReadyToSend = false

    enum Operation {
        case requestMTU
        case discoverServices
        case discoverCharacteristics(AndroidService)
        case discoverDescriptors(AndroidCharacteristic)
        case read(AndroidCharacteristic)
        case write(AndroidCharacteristic, [UInt8], WriteType)
        case notify(AndroidCharacteristic, Bool)
        case readDescriptor(AndroidDescriptor)
        case writeDescriptor(AndroidDescriptor, [UInt8])
        case readRSSI
    }

    init(address: String, central: AndroidCentral?) {
        self.address = address
        self.central = central
    }

    deinit {
        release()
    }

    /// Lets the connection go with its central.
    func release() {
        HostBackground.set(.bluetooth, false, for: self)
        if let timeout {
            MainLooper.shared.cancel(timeout)
            self.timeout = nil
        }
        if let handle {
            BluetoothHub.shared.removeConnection(handle)
            self.handle = nil
        }
        connection?.disconnect()
        connection?.close()
        connection = nil
    }

    public func identifier() -> String { address }

    public func name() -> String? {
        if let name = connection?.name(), !name.isEmpty {
            return name
        }
        return knownName
    }

    public func state() -> Int32 { peripheralState.rawValue }

    public func setDelegate(_ delegate: (any BluetoothPeripheralDelegate)?) {
        self.delegate = delegate
    }

    public func services() -> [any BluetoothService] { discovered }

    // MARK: Connecting

    func connect(timeout milliseconds: Int32) {
        guard peripheralState == .disconnected, let central else { return }
        cancelRequested = false
        let handle = BluetoothHub.shared.add(self)
        self.handle = handle
        let connection = central.hub.system.makeConnection(handle: handle, address: address)
        self.connection = connection
        peripheralState = .connecting
        guard connection.connect() else {
            finishConnecting(failing: .connectionFailed)
            return
        }
        if milliseconds > 0 {
            self.timeout = MainLooper.shared.schedule(after: Int64(milliseconds) * 1_000_000) { [weak self] in
                self?.timedOut()
            }
        }
    }

    private func timedOut() {
        timeout = nil
        guard peripheralState == .connecting else { return }
        finishConnecting(failing: .connectionTimeout)
    }

    private func finishConnecting(failing error: BluetoothError) {
        release()
        peripheralState = .disconnected
        failAll()
        central?.didFailToConnect(self, error: error)
    }

    func cancelConnection() {
        switch peripheralState {
        case .connecting:
            cancelRequested = true
            release()
            peripheralState = .disconnected
            failAll()
            central?.didDisconnect(self, error: 0)
        case .connected:
            cancelRequested = true
            peripheralState = .disconnecting
            connection?.disconnect()
        case .disconnecting, .disconnected:
            break
        }
    }

    func adapterTurnedOff() {
        guard peripheralState != .disconnected else { return }
        let wasConnecting = peripheralState == .connecting
        release()
        peripheralState = .disconnected
        failAll()
        if wasConnecting {
            central?.didFailToConnect(self, error: .poweredOff)
        } else {
            central?.didDisconnect(self, error: BluetoothError.poweredOff.rawValue)
        }
    }

    /// `onConnectionStateChange`.
    func connectionChanged(status: Int32, connected: Bool) {
        if connected, status == 0 {
            guard peripheralState == .connecting else { return }
            enqueue(.requestMTU)
            return
        }
        let previous = peripheralState
        release()
        peripheralState = .disconnected
        failAll()
        switch previous {
        case .connecting:
            central?.didFailToConnect(self, error: BluetoothMapping.connectError(status: status))
        case .connected, .disconnecting:
            central?.didDisconnect(self, error: BluetoothMapping.disconnectError(status: status, requested: cancelRequested))
        case .disconnected:
            break
        }
    }

    /// The MTU request ends the connection's setup either way.
    func mtuChanged(_ mtu: Int32, status: Int32) {
        if status == 0 {
            self.mtu = mtu
        }
        guard case .requestMTU = running else { return }
        running = nil
        if peripheralState == .connecting {
            if let timeout {
                MainLooper.shared.cancel(timeout)
                self.timeout = nil
            }
            peripheralState = .connected
            HostBackground.set(.bluetooth, true, for: self)
            central?.didConnect(self)
        }
        runNext()
    }

    // MARK: Operations

    public func discoverServices(_ uuids: [BluetoothUUID]) {
        enqueue(.discoverServices)
    }

    public func discoverCharacteristics(_ uuids: [BluetoothUUID], for service: any BluetoothService) {
        guard let service = own(service) else { return }
        // Android discovers everything at once: report what's there.
        enqueue(.discoverCharacteristics(service))
    }

    public func discoverDescriptors(for characteristic: any BluetoothCharacteristic) {
        guard let characteristic = own(characteristic) else { return }
        enqueue(.discoverDescriptors(characteristic))
    }

    public func readValue(_ characteristic: any BluetoothCharacteristic) {
        guard let characteristic = own(characteristic) else { return }
        enqueue(.read(characteristic))
    }

    public func writeValue(_ value: [UInt8], for characteristic: any BluetoothCharacteristic, type: Int32) {
        guard let characteristic = own(characteristic) else { return }
        let type = WriteType(rawValue: type) ?? .withResponse
        if type == .withoutResponse {
            writesWithoutResponse += 1
        }
        enqueue(.write(characteristic, value, type))
    }

    public func setNotifyValue(_ enabled: Bool, for characteristic: any BluetoothCharacteristic) {
        guard let characteristic = own(characteristic) else { return }
        enqueue(.notify(characteristic, enabled))
    }

    public func readDescriptor(_ descriptor: any BluetoothDescriptor) {
        guard let descriptor = own(descriptor) else { return }
        enqueue(.readDescriptor(descriptor))
    }

    public func writeDescriptor(_ value: [UInt8], for descriptor: any BluetoothDescriptor) {
        guard let descriptor = own(descriptor) else { return }
        enqueue(.writeDescriptor(descriptor, value))
    }

    public func readRSSI() {
        enqueue(.readRSSI)
    }

    /// Long writes for writes with response; the ATT MTU less its header
    /// without.
    public func maximumWriteLength(_ type: Int32) -> Int32 {
        WriteType(rawValue: type) == .withoutResponse ? mtu - 3 : 512
    }

    public func canSendWriteWithoutResponse() -> Bool {
        guard writesWithoutResponse == 0 else {
            owesReadyToSend = true
            return false
        }
        return true
    }

    private func own(_ service: any BluetoothService) -> AndroidService? {
        HostObjects.own(service, as: AndroidService.self).flatMap { $0.owner === self ? $0 : nil }
    }

    private func own(_ characteristic: any BluetoothCharacteristic) -> AndroidCharacteristic? {
        HostObjects.own(characteristic, as: AndroidCharacteristic.self).flatMap { $0.owner?.owner === self ? $0 : nil }
    }

    private func own(_ descriptor: any BluetoothDescriptor) -> AndroidDescriptor? {
        HostObjects.own(descriptor, as: AndroidDescriptor.self).flatMap { $0.owner?.owner?.owner === self ? $0 : nil }
    }

    private func enqueue(_ operation: Operation) {
        queue.append(operation)
        if running == nil {
            runNext()
        }
    }

    /// Starts the next operation; those Android refuses, or that need no
    /// call, complete at once.
    private func runNext() {
        while running == nil, !queue.isEmpty {
            let operation = queue.removeFirst()
            guard let connection, peripheralState == .connected || isSetup(operation) else {
                fail(operation, BluetoothError.notConnected.rawValue)
                continue
            }
            if start(operation, on: connection) {
                running = operation
            }
        }
    }

    private func isSetup(_ operation: Operation) -> Bool {
        if case .requestMTU = operation, peripheralState == .connecting {
            return true
        }
        return false
    }

    /// Whether the operation now waits for its callback.
    private func start(_ operation: Operation, on connection: any GattConnection) -> Bool {
        let refused = BluetoothError.unknown.rawValue
        switch operation {
        case .requestMTU:
            guard connection.requestMTU(BluetoothMapping.maximumMTU) else {
                // Without an MTU exchange, the connection is still good.
                running = operation
                mtuChanged(mtu, status: 1)
                return false
            }
            return true
        case .discoverServices:
            guard connection.discoverServices() else {
                delegate?.didDiscoverServices(self, error: refused)
                return false
            }
            return true
        case .discoverCharacteristics(let service):
            delegate?.didDiscoverCharacteristics(self, service: service, error: 0)
            return false
        case .discoverDescriptors(let characteristic):
            delegate?.didDiscoverDescriptors(self, characteristic: characteristic, error: 0)
            return false
        case .read(let characteristic):
            guard connection.readCharacteristic(characteristic.id) else {
                delegate?.didUpdateValue(self, characteristic: characteristic, value: [], error: refused)
                return false
            }
            return true
        case .write(let characteristic, let value, let type):
            guard connection.writeCharacteristic(characteristic.id, value: value, writeType: BluetoothMapping.writeType(type)) else {
                finishWrite(characteristic, type: type, error: refused)
                return false
            }
            return true
        case .notify(let characteristic, let enabled):
            guard connection.setNotification(characteristic.id, enabled: enabled),
                  connection.writeDescriptor(characteristic: characteristic.id, uuid: BluetoothMapping.cccd,
                                             value: BluetoothMapping.cccdValue(enabled: enabled, properties: characteristic.flags)) else {
                delegate?.didUpdateNotificationState(self, characteristic: characteristic, error: refused)
                return false
            }
            return true
        case .readDescriptor(let descriptor):
            guard let characteristic = descriptor.owner,
                  connection.readDescriptor(characteristic: characteristic.id, uuid: descriptor.fullUUID) else {
                delegate?.didUpdateDescriptorValue(self, descriptor: descriptor, value: [], error: refused)
                return false
            }
            return true
        case .writeDescriptor(let descriptor, let value):
            guard let characteristic = descriptor.owner,
                  connection.writeDescriptor(characteristic: characteristic.id, uuid: descriptor.fullUUID, value: value) else {
                delegate?.didWriteDescriptorValue(self, descriptor: descriptor, error: refused)
                return false
            }
            descriptor.pending = value
            return true
        case .readRSSI:
            guard connection.readRSSI() else {
                delegate?.didReadRSSI(self, rssi: 0, error: refused)
                return false
            }
            return true
        }
    }

    /// The delegate's one callback for an operation that can't run.
    private func fail(_ operation: Operation, _ error: Int32) {
        switch operation {
        case .requestMTU: break
        case .discoverServices: delegate?.didDiscoverServices(self, error: error)
        case .discoverCharacteristics(let service): delegate?.didDiscoverCharacteristics(self, service: service, error: error)
        case .discoverDescriptors(let characteristic): delegate?.didDiscoverDescriptors(self, characteristic: characteristic, error: error)
        case .read(let characteristic): delegate?.didUpdateValue(self, characteristic: characteristic, value: [], error: error)
        case .write(let characteristic, _, let type): finishWrite(characteristic, type: type, error: error)
        case .notify(let characteristic, _): delegate?.didUpdateNotificationState(self, characteristic: characteristic, error: error)
        case .readDescriptor(let descriptor): delegate?.didUpdateDescriptorValue(self, descriptor: descriptor, value: [], error: error)
        case .writeDescriptor(let descriptor, _): delegate?.didWriteDescriptorValue(self, descriptor: descriptor, error: error)
        case .readRSSI: delegate?.didReadRSSI(self, rssi: 0, error: error)
        }
    }

    /// Everything queued or running fails with `notConnected`.
    private func failAll() {
        var pending = queue
        if let running, !isMTU(running) {
            pending.insert(running, at: 0)
        }
        running = nil
        queue = []
        for operation in pending {
            fail(operation, BluetoothError.notConnected.rawValue)
        }
    }

    private func isMTU(_ operation: Operation) -> Bool {
        if case .requestMTU = operation { return true }
        return false
    }

    /// A write with response tells the delegate; one without only frees
    /// the way for the next.
    private func finishWrite(_ characteristic: AndroidCharacteristic, type: WriteType, error: Int32) {
        if type == .withResponse {
            delegate?.didWriteValue(self, characteristic: characteristic, error: error)
            return
        }
        writesWithoutResponse = max(0, writesWithoutResponse - 1)
        if writesWithoutResponse == 0, owesReadyToSend {
            owesReadyToSend = false
            delegate?.isReadyToSendWriteWithoutResponse(self)
        }
    }

    // MARK: Callbacks

    func servicesDiscovered(status: Int32) {
        guard case .discoverServices = running else { return }
        running = nil
        if status == 0, let connection {
            discovered = AndroidService.build(connection.services(), owner: self)
        }
        delegate?.didDiscoverServices(self, error: BluetoothMapping.operationError(status))
        runNext()
    }

    func characteristicRead(_ id: Int32, value: [UInt8], status: Int32) {
        guard case .read(let characteristic) = running, characteristic.id == id else { return }
        running = nil
        if status == 0 {
            characteristic.lastValue = value
        }
        delegate?.didUpdateValue(self, characteristic: characteristic, value: value, error: BluetoothMapping.operationError(status))
        runNext()
    }

    func characteristicWritten(_ id: Int32, status: Int32) {
        guard case .write(let characteristic, _, let type) = running, characteristic.id == id else { return }
        running = nil
        finishWrite(characteristic, type: type, error: BluetoothMapping.operationError(status))
        runNext()
    }

    /// A notification or indication: not an operation of the queue.
    func characteristicChanged(_ id: Int32, value: [UInt8]) {
        guard let characteristic = characteristic(id) else { return }
        characteristic.lastValue = value
        delegate?.didUpdateValue(self, characteristic: characteristic, value: value, error: 0)
    }

    func descriptorRead(characteristic id: Int32, uuid: String, value: [UInt8], status: Int32) {
        guard case .readDescriptor(let descriptor) = running, descriptor.owner?.id == id, descriptor.fullUUID == uuid.uppercased() else { return }
        running = nil
        if status == 0 {
            descriptor.lastValue = value
        }
        delegate?.didUpdateDescriptorValue(self, descriptor: descriptor, value: value, error: BluetoothMapping.operationError(status))
        runNext()
    }

    func descriptorWritten(characteristic id: Int32, uuid: String, status: Int32) {
        switch running {
        case .notify(let characteristic, let enabled) where characteristic.id == id:
            running = nil
            if status == 0 {
                characteristic.notifying = enabled
            }
            delegate?.didUpdateNotificationState(self, characteristic: characteristic, error: BluetoothMapping.operationError(status))
        case .writeDescriptor(let descriptor, _) where descriptor.owner?.id == id && descriptor.fullUUID == uuid.uppercased():
            running = nil
            if status == 0 {
                descriptor.lastValue = descriptor.pending
            }
            delegate?.didWriteDescriptorValue(self, descriptor: descriptor, error: BluetoothMapping.operationError(status))
        default:
            return
        }
        runNext()
    }

    func rssiRead(_ rssi: Int32, status: Int32) {
        guard case .readRSSI = running else { return }
        running = nil
        delegate?.didReadRSSI(self, rssi: rssi, error: BluetoothMapping.operationError(status))
        runNext()
    }

    func servicesChanged() {
        discovered = []
        delegate?.didModifyServices(self)
    }

    private func characteristic(_ id: Int32) -> AndroidCharacteristic? {
        for service in discovered {
            if let characteristic = service.children.first(where: { $0.id == id }) {
                return characteristic
            }
        }
        return nil
    }
}
