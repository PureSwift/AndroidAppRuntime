import AndroidHostBluetooth
import SwiftJava

/// The Kotlin `BluetoothSystem` (`:appruntime-contracts`).
@JavaClass("org.pureswift.appruntime.contracts.BluetoothSystem")
open class JavaBluetoothSystem: JavaObject {

    @JavaMethod
    @_nonoverride public convenience init(environment: JNIEnvironment? = nil)

    @JavaMethod open func hasLowEnergy() -> Bool
    @JavaMethod open func adapterState() -> Int32
    @JavaMethod open func setStateListening(_ on: Bool)
    @JavaMethod open func startScan(_ central: Int64, _ services: [String], _ mode: Int32) -> Bool
    @JavaMethod open func stopScan(_ central: Int64)
    @JavaMethod open func bondedAddresses() -> [String]
    @JavaMethod open func connectedAddresses() -> [String]
    @JavaMethod open func makeConnection(_ handle: Int64, _ address: String) -> JavaGattConnection!
}

@JavaClass("org.pureswift.appruntime.contracts.GattConnection")
open class JavaGattConnection: JavaObject {
    @JavaMethod open func connect() -> Bool
    @JavaMethod open func disconnect()
    @JavaMethod open func close()
    @JavaMethod open func discoverServices() -> Bool
    @JavaMethod open func serviceNumbers() -> [Int32]
    @JavaMethod open func serviceUUIDs() -> [String]
    @JavaMethod open func requestMtu(_ mtu: Int32) -> Bool
    @JavaMethod open func readCharacteristic(_ id: Int32) -> Bool
    @JavaMethod open func writeCharacteristic(_ id: Int32, _ value: [UInt8], _ writeType: Int32) -> Bool
    @JavaMethod open func setNotification(_ id: Int32, _ enabled: Bool) -> Bool
    @JavaMethod open func readDescriptor(_ characteristic: Int32, _ uuid: String) -> Bool
    @JavaMethod open func writeDescriptor(_ characteristic: Int32, _ uuid: String, _ value: [UInt8]) -> Bool
    @JavaMethod open func readRssi() -> Bool
    @JavaMethod open func name() -> String
}

/// `AndroidHostBluetooth`'s system over the Kotlin class.
final class AndroidBluetoothSystem: BluetoothSystem {

    let java = JavaBluetoothSystem()

    func hasLowEnergy() -> Bool { java.hasLowEnergy() }

    func adapterState() -> Int32 { java.adapterState() }

    func setStateListening(_ on: Bool) { java.setStateListening(on) }

    func startScan(central: Int64, services: [String], mode: Int32) -> Bool {
        java.startScan(central, services, mode)
    }

    func stopScan(central: Int64) { java.stopScan(central) }

    func bondedAddresses() -> [String] { java.bondedAddresses() }

    func connectedAddresses() -> [String] { java.connectedAddresses() }

    func makeConnection(handle: Int64, address: String) -> any GattConnection {
        ConnectionAdapter(java.makeConnection(handle, address))
    }

    final class ConnectionAdapter: GattConnection {

        let java: JavaGattConnection

        init(_ java: JavaGattConnection) {
            self.java = java
        }

        func connect() -> Bool { java.connect() }
        func disconnect() { java.disconnect() }
        func close() { java.close() }
        func discoverServices() -> Bool { java.discoverServices() }

        func services() -> [GattItem] {
            GattItem.decode(numbers: java.serviceNumbers(), uuids: java.serviceUUIDs())
        }

        func requestMTU(_ mtu: Int32) -> Bool { java.requestMtu(mtu) }
        func readCharacteristic(_ id: Int32) -> Bool { java.readCharacteristic(id) }

        func writeCharacteristic(_ id: Int32, value: [UInt8], writeType: Int32) -> Bool {
            java.writeCharacteristic(id, value, writeType)
        }

        func setNotification(_ id: Int32, enabled: Bool) -> Bool { java.setNotification(id, enabled) }

        func readDescriptor(characteristic: Int32, uuid: String) -> Bool {
            java.readDescriptor(characteristic, uuid)
        }

        func writeDescriptor(characteristic: Int32, uuid: String, value: [UInt8]) -> Bool {
            java.writeDescriptor(characteristic, uuid, value)
        }

        func readRSSI() -> Bool { java.readRssi() }
        func name() -> String { java.name() }
    }
}

/// The Kotlin `BluetoothNatives` object.
@JavaClass("org.pureswift.appruntime.contracts.BluetoothNatives")
open class BluetoothNatives: JavaObject {}

@JavaImplementation("org.pureswift.appruntime.contracts.BluetoothNatives")
extension BluetoothNatives {

    @JavaMethod
    public func adapterStateChanged() {
        BluetoothHub.shared.adapterStateChanged()
    }

    @JavaMethod
    public func scanResult(_ central: Int64, _ address: String, _ name: String, _ rssi: Int32, _ connectable: Int32, _ record: [UInt8]) {
        BluetoothHub.shared.scanResult(central: central, address: address, name: name, rssi: rssi, connectable: connectable, record: record)
    }

    @JavaMethod
    public func scanFailed(_ central: Int64, _ code: Int32) {
        BluetoothHub.shared.scanFailed(central: central, code: code)
    }

    @JavaMethod
    public func connectionStateChanged(_ handle: Int64, _ status: Int32, _ connected: Bool) {
        BluetoothHub.shared.connectionStateChanged(handle: handle, status: status, connected: connected)
    }

    @JavaMethod
    public func servicesDiscovered(_ handle: Int64, _ status: Int32) {
        BluetoothHub.shared.servicesDiscovered(handle: handle, status: status)
    }

    @JavaMethod
    public func mtuChanged(_ handle: Int64, _ mtu: Int32, _ status: Int32) {
        BluetoothHub.shared.mtuChanged(handle: handle, mtu: mtu, status: status)
    }

    @JavaMethod
    public func characteristicRead(_ handle: Int64, _ id: Int32, _ value: [UInt8], _ status: Int32) {
        BluetoothHub.shared.characteristicRead(handle: handle, id: id, value: value, status: status)
    }

    @JavaMethod
    public func characteristicWritten(_ handle: Int64, _ id: Int32, _ status: Int32) {
        BluetoothHub.shared.characteristicWritten(handle: handle, id: id, status: status)
    }

    @JavaMethod
    public func characteristicChanged(_ handle: Int64, _ id: Int32, _ value: [UInt8]) {
        BluetoothHub.shared.characteristicChanged(handle: handle, id: id, value: value)
    }

    @JavaMethod
    public func descriptorRead(_ handle: Int64, _ characteristic: Int32, _ uuid: String, _ value: [UInt8], _ status: Int32) {
        BluetoothHub.shared.descriptorRead(handle: handle, characteristic: characteristic, uuid: uuid, value: value, status: status)
    }

    @JavaMethod
    public func descriptorWritten(_ handle: Int64, _ characteristic: Int32, _ uuid: String, _ status: Int32) {
        BluetoothHub.shared.descriptorWritten(handle: handle, characteristic: characteristic, uuid: uuid, status: status)
    }

    @JavaMethod
    public func rssiRead(_ handle: Int64, _ rssi: Int32, _ status: Int32) {
        BluetoothHub.shared.rssiRead(handle: handle, rssi: rssi, status: status)
    }

    @JavaMethod
    public func servicesChanged(_ handle: Int64) {
        BluetoothHub.shared.servicesChanged(handle: handle)
    }
}
