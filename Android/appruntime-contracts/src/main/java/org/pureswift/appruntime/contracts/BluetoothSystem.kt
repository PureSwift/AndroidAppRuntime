package org.pureswift.appruntime.contracts

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.ParcelUuid
import androidx.core.content.ContextCompat
import java.util.UUID

/**
 * The Bluetooth contracts' Android side (Swift's `AndroidHostBluetooth`):
 * the adapter, `BluetoothLeScanner` and `BluetoothGatt`, with callbacks on
 * the main looper for [BluetoothNatives]. Swift checks the permissions and
 * queues GATT operations; a `SecurityException` here means a permission
 * went away, and the call reports failure. Main thread only.
 */
@SuppressLint("MissingPermission")
class BluetoothSystem {

    private val context: Context get() = HostContext.application

    private val adapter: BluetoothAdapter? get() = context.getSystemService(BluetoothManager::class.java)?.adapter

    fun hasLowEnergy(): Boolean = context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)

    fun adapterState(): Int = adapter?.state ?: -1

    private val stateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) = BluetoothNatives.adapterStateChanged()
    }

    fun setStateListening(on: Boolean) {
        if (on) {
            ContextCompat.registerReceiver(context, stateReceiver, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED),
                                           ContextCompat.RECEIVER_NOT_EXPORTED)
        } else {
            runCatching { context.unregisterReceiver(stateReceiver) }
        }
    }

    private val scans = mutableMapOf<Long, ScanCallback>()

    /** `services` are 128-bit UUID strings; `mode` a `ScanSettings.SCAN_MODE_*`. */
    fun startScan(central: Long, services: Array<String>, mode: Int): Boolean {
        val scanner = adapter?.bluetoothLeScanner ?: return false
        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) = report(central, result)

            override fun onBatchScanResults(results: MutableList<ScanResult>) = results.forEach { report(central, it) }

            override fun onScanFailed(errorCode: Int) {
                scans.remove(central)
                BluetoothNatives.scanFailed(central, errorCode)
            }
        }
        val filters = services.map { ScanFilter.Builder().setServiceUuid(ParcelUuid(UUID.fromString(it))).build() }
        val settings = ScanSettings.Builder().setScanMode(mode).build()
        return try {
            scanner.startScan(filters, settings, callback)
            scans[central] = callback
            true
        } catch (error: SecurityException) {
            false
        }
    }

    private fun report(central: Long, result: ScanResult) {
        val connectable = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) (if (result.isConnectable) 1 else 0) else -1
        val name = runCatching { result.device.name }.getOrNull() ?: result.scanRecord?.deviceName ?: ""
        BluetoothNatives.scanResult(central, result.device.address, name, result.rssi, connectable,
                                    result.scanRecord?.bytes ?: ByteArray(0))
    }

    fun stopScan(central: Long) {
        val callback = scans.remove(central) ?: return
        runCatching { adapter?.bluetoothLeScanner?.stopScan(callback) }
    }

    fun bondedAddresses(): Array<String> =
        runCatching { adapter?.bondedDevices?.map { it.address }?.toTypedArray() }.getOrNull() ?: emptyArray()

    fun connectedAddresses(): Array<String> = runCatching {
        context.getSystemService(BluetoothManager::class.java).getConnectedDevices(BluetoothProfile.GATT).map { it.address }.toTypedArray()
    }.getOrNull() ?: emptyArray()

    fun makeConnection(handle: Long, address: String): GattConnection = GattConnection(handle, address)
}

/** One `BluetoothGatt`; characteristics by instance ID, descriptors by their characteristic and UUID. */
@SuppressLint("MissingPermission")
class GattConnection(private val handle: Long, private val address: String) {

    private var gatt: BluetoothGatt? = null

    private val characteristics = mutableMapOf<Int, BluetoothGattCharacteristic>()

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) =
            BluetoothNatives.connectionStateChanged(handle, status, newState == BluetoothProfile.STATE_CONNECTED)

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) =
            BluetoothNatives.servicesDiscovered(handle, status)

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) =
            BluetoothNatives.mtuChanged(handle, mtu, status)

        @Deprecated("Deprecated in API 33")
        override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            @Suppress("DEPRECATION")
            BluetoothNatives.characteristicRead(handle, characteristic.instanceId, characteristic.value ?: ByteArray(0), status)
        }

        override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray, status: Int) =
            BluetoothNatives.characteristicRead(handle, characteristic.instanceId, value, status)

        override fun onCharacteristicWrite(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) =
            BluetoothNatives.characteristicWritten(handle, characteristic.instanceId, status)

        @Deprecated("Deprecated in API 33")
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            @Suppress("DEPRECATION")
            BluetoothNatives.characteristicChanged(handle, characteristic.instanceId, characteristic.value ?: ByteArray(0))
        }

        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) =
            BluetoothNatives.characteristicChanged(handle, characteristic.instanceId, value)

        @Deprecated("Deprecated in API 33")
        override fun onDescriptorRead(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            @Suppress("DEPRECATION")
            BluetoothNatives.descriptorRead(handle, descriptor.characteristic.instanceId, descriptor.uuid.toString(),
                                            descriptor.value ?: ByteArray(0), status)
        }

        override fun onDescriptorRead(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int, value: ByteArray) =
            BluetoothNatives.descriptorRead(handle, descriptor.characteristic.instanceId, descriptor.uuid.toString(), value, status)

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) =
            BluetoothNatives.descriptorWritten(handle, descriptor.characteristic.instanceId, descriptor.uuid.toString(), status)

        override fun onReadRemoteRssi(gatt: BluetoothGatt, rssi: Int, status: Int) =
            BluetoothNatives.rssiRead(handle, rssi, status)

        override fun onServiceChanged(gatt: BluetoothGatt) =
            BluetoothNatives.servicesChanged(handle)
    }

    fun connect(): Boolean = try {
        val context = HostContext.application
        val adapter = context.getSystemService(BluetoothManager::class.java).adapter
        val device: BluetoothDevice = adapter.getRemoteDevice(address)
        gatt = device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE, BluetoothDevice.PHY_LE_1M_MASK, HostContext.main)
        gatt != null
    } catch (error: RuntimeException) {
        false
    }

    fun disconnect() {
        runCatching { gatt?.disconnect() }
    }

    fun close() {
        runCatching { gatt?.close() }
        gatt = null
        characteristics.clear()
    }

    private inline fun attempt(body: (BluetoothGatt) -> Boolean): Boolean {
        val gatt = gatt ?: return false
        return try {
            body(gatt)
        } catch (error: SecurityException) {
            false
        }
    }

    fun discoverServices(): Boolean = attempt { it.discoverServices() }

    /** Three numbers per attribute (kind, instance ID, flags), for [serviceUUIDs]'s order. */
    fun serviceNumbers(): IntArray {
        val numbers = mutableListOf<Int>()
        characteristics.clear()
        for (service in gatt?.services.orEmpty()) {
            numbers += listOf(0, service.instanceId, if (service.type == 0) 1 else 0)
            for (characteristic in service.characteristics) {
                characteristics[characteristic.instanceId] = characteristic
                numbers += listOf(1, characteristic.instanceId, characteristic.properties)
                for (descriptor in characteristic.descriptors) numbers += listOf(2, 0, 0)
            }
        }
        return numbers.toIntArray()
    }

    fun serviceUUIDs(): Array<String> = gatt?.services.orEmpty().flatMap { service ->
        listOf(service.uuid.toString()) + service.characteristics.flatMap { characteristic ->
            listOf(characteristic.uuid.toString()) + characteristic.descriptors.map { it.uuid.toString() }
        }
    }.toTypedArray()

    fun requestMtu(mtu: Int): Boolean = attempt { it.requestMtu(mtu) }

    fun readCharacteristic(id: Int): Boolean = attempt { gatt ->
        characteristics[id]?.let(gatt::readCharacteristic) ?: false
    }

    fun writeCharacteristic(id: Int, value: ByteArray, writeType: Int): Boolean = attempt { gatt ->
        val characteristic = characteristics[id] ?: return@attempt false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gatt.writeCharacteristic(characteristic, value, writeType) == BluetoothGatt.GATT_SUCCESS
        } else {
            @Suppress("DEPRECATION")
            characteristic.writeType = writeType
            @Suppress("DEPRECATION")
            characteristic.value = value
            @Suppress("DEPRECATION")
            gatt.writeCharacteristic(characteristic)
        }
    }

    fun setNotification(id: Int, enabled: Boolean): Boolean = attempt { gatt ->
        characteristics[id]?.let { gatt.setCharacteristicNotification(it, enabled) } ?: false
    }

    private fun descriptor(characteristic: Int, uuid: String): BluetoothGattDescriptor? =
        characteristics[characteristic]?.getDescriptor(UUID.fromString(uuid))

    fun readDescriptor(characteristic: Int, uuid: String): Boolean = attempt { gatt ->
        descriptor(characteristic, uuid)?.let(gatt::readDescriptor) ?: false
    }

    fun writeDescriptor(characteristic: Int, uuid: String, value: ByteArray): Boolean = attempt { gatt ->
        val descriptor = descriptor(characteristic, uuid) ?: return@attempt false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gatt.writeDescriptor(descriptor, value) == BluetoothGatt.GATT_SUCCESS
        } else {
            @Suppress("DEPRECATION")
            descriptor.value = value
            @Suppress("DEPRECATION")
            gatt.writeDescriptor(descriptor)
        }
    }

    fun readRssi(): Boolean = attempt { it.readRemoteRssi() }

    fun name(): String = runCatching { gatt?.device?.name }.getOrNull() ?: ""
}

/** What the adapter, scans and connections report, on the main thread, for Swift's `BluetoothHub`. */
object BluetoothNatives {

    external fun adapterStateChanged()

    external fun scanResult(central: Long, address: String, name: String, rssi: Int, connectable: Int, record: ByteArray)

    external fun scanFailed(central: Long, code: Int)

    external fun connectionStateChanged(handle: Long, status: Int, connected: Boolean)

    external fun servicesDiscovered(handle: Long, status: Int)

    external fun mtuChanged(handle: Long, mtu: Int, status: Int)

    external fun characteristicRead(handle: Long, id: Int, value: ByteArray, status: Int)

    external fun characteristicWritten(handle: Long, id: Int, status: Int)

    external fun characteristicChanged(handle: Long, id: Int, value: ByteArray)

    external fun descriptorRead(handle: Long, characteristic: Int, uuid: String, value: ByteArray, status: Int)

    external fun descriptorWritten(handle: Long, characteristic: Int, uuid: String, status: Int)

    external fun rssiRead(handle: Long, rssi: Int, status: Int)

    external fun servicesChanged(handle: Long)
}
