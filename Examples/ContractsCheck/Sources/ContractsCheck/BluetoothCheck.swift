import DynamicBluetooth
import DynamicRuntime

/// `Central`: the Nearby devices prompt (the script taps "Allow"), the
/// state, and a scan. What the scan finds depends on what's around, so
/// it's noted; when something connectable turns up, the check connects,
/// discovers its services and disconnects.
final class BluetoothCheck: CentralDelegate, PeripheralDelegate {

    let report: Report

    var central: Central?

    private var authorizations = 0

    private var discovered = 0

    private var target: Peripheral?

    init(report: Report) {
        self.report = report
    }

    func run() {
        let status = CentralProxy.authorizationStatus()
        report.check(status == BluetoothAuthorization.notDetermined.rawValue, "bluetooth.authorizationStatus \(status)")
        central = CentralProxy.make(self)
    }

    func didChangeAuthorization(_ central: Central, status: Int32) {
        authorizations += 1
        if authorizations == 1, status == BluetoothAuthorization.notDetermined.rawValue {
            report.note("bluetooth.requesting")
            central.requestAuthorization()
            return
        }
        report.check(status == BluetoothAuthorization.allowed.rawValue, "bluetooth.didChangeAuthorization \(status)")
        Checks.startMotion()
    }

    func didUpdateState(_ central: Central, state: Int32) {
        guard state != CentralState.unauthorized.rawValue else { return }
        report.check(state == CentralState.poweredOn.rawValue, "bluetooth.didUpdateState \(state)")
        guard state == CentralState.poweredOn.rawValue else { return }
        central.scan(services: [], allowDuplicates: false, mode: ScanMode.lowLatency.rawValue)
        report.check(central.isScanning(), "bluetooth.isScanning")
    }

    func didDiscover(_ central: Central, peripheral: Peripheral, advertisement: Advertisement, rssi: Int32) {
        discovered += 1
        guard discovered <= 5 else { return }
        report.note("bluetooth.discovered \(peripheral.identifier()) \(advertisement.localName() ?? peripheral.name() ?? "-") \(rssi) dBm")
        report.check(peripheral.address != nil, "bluetooth.identifier is an address")
        guard target == nil, advertisement.isConnectable() == 1 else { return }
        target = peripheral
        central.stopScan()
        peripheral.setDelegate(self)
        central.connect(peripheral, timeout: 15_000)
    }

    func didStopScanning(_ central: Central, error: Int32) {
        report.check(false, "bluetooth.didStopScanning \(error)")
    }

    func didConnect(_ central: Central, peripheral: Peripheral) {
        report.check(peripheral.state() == PeripheralState.connected.rawValue, "bluetooth.didConnect")
        peripheral.discoverServices([])
    }

    func didFailToConnect(_ central: Central, peripheral: Peripheral, error: Int32) {
        report.note("bluetooth.didFailToConnect \(error)")
    }

    func didDisconnect(_ central: Central, peripheral: Peripheral, error: Int32) {
        report.check(error == 0, "bluetooth.didDisconnect \(error)")
    }

    func didDiscoverServices(_ peripheral: Peripheral, error: Int32) {
        report.check(error == 0, "bluetooth.didDiscoverServices \(peripheral.services().count) \(error)")
        central?.cancelConnection(peripheral)
    }

    func didDiscoverCharacteristics(_ peripheral: Peripheral, service: Service, error: Int32) {}
    func didDiscoverDescriptors(_ peripheral: Peripheral, characteristic: Characteristic, error: Int32) {}
    func didUpdateValue(_ peripheral: Peripheral, characteristic: Characteristic, value: [UInt8], error: Int32) {}
    func didWriteValue(_ peripheral: Peripheral, characteristic: Characteristic, error: Int32) {}
    func didUpdateNotificationState(_ peripheral: Peripheral, characteristic: Characteristic, error: Int32) {}
    func didUpdateDescriptorValue(_ peripheral: Peripheral, descriptor: Descriptor, value: [UInt8], error: Int32) {}
    func didWriteDescriptorValue(_ peripheral: Peripheral, descriptor: Descriptor, error: Int32) {}
    func didReadRSSI(_ peripheral: Peripheral, rssi: Int32, error: Int32) {}
    func isReadyToSendWriteWithoutResponse(_ peripheral: Peripheral) {}
    func didModifyServices(_ peripheral: Peripheral) {}
    func didUpdateName(_ peripheral: Peripheral) {}
}
