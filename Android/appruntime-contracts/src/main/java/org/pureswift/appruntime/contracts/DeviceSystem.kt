package org.pureswift.appruntime.contracts

import android.app.ActivityManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.content.ContextCompat
import java.util.UUID

/**
 * The `Device` contract's Android side (Swift's `AndroidHostDevice`): the
 * raw values Swift maps, and the listeners whose readings go to
 * [DeviceNatives]. Main thread only.
 */
class DeviceSystem {

    private val context: Context get() = HostContext.application

    // Facts

    fun model(): String = Build.MODEL ?: ""

    fun manufacturer(): String = Build.MANUFACTURER ?: ""

    fun release(): String = Build.VERSION.RELEASE ?: ""

    fun apiLevel(): Int = Build.VERSION.SDK_INT

    fun uiModeType(): Int = context.resources.configuration.uiMode and Configuration.UI_MODE_TYPE_MASK

    fun smallestWidthDp(): Int = context.resources.configuration.smallestScreenWidthDp

    fun isPC(): Boolean = context.packageManager.hasSystemFeature("android.hardware.type.pc")

    fun fingerprint(): String = Build.FINGERPRINT ?: ""

    fun hardware(): String = Build.HARDWARE ?: ""

    fun product(): String = Build.PRODUCT ?: ""

    /** A UUID made from `ANDROID_ID`, which is per signing key, user and device; empty if there's none. */
    fun vendorIdentifier(): String {
        val id = Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID) ?: return ""
        return UUID.nameUUIDFromBytes(id.toByteArray()).toString().uppercase()
    }

    fun physicalMemory(): Long {
        val info = ActivityManager.MemoryInfo()
        context.getSystemService(ActivityManager::class.java).getMemoryInfo(info)
        return info.totalMem
    }

    fun processorCount(): Int = Runtime.getRuntime().availableProcessors()

    // State

    fun name(): String =
        Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME) ?: Build.MODEL ?: ""

    /** Level, scale, status, plugged and present (1 or 0); empty if there's no broadcast. */
    fun battery(): IntArray {
        val intent = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED)) ?: return IntArray(0)
        return battery(intent)
    }

    private fun battery(intent: Intent): IntArray = intArrayOf(
        intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1),
        intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1),
        intent.getIntExtra(BatteryManager.EXTRA_STATUS, BatteryManager.BATTERY_STATUS_UNKNOWN),
        intent.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0),
        if (intent.getBooleanExtra(BatteryManager.EXTRA_PRESENT, true)) 1 else 0,
    )

    private val power: PowerManager get() = context.getSystemService(PowerManager::class.java)

    fun isPowerSaveMode(): Boolean = power.isPowerSaveMode

    fun thermalStatus(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) power.currentThermalStatus else 0

    private val sensors: SensorManager get() = context.getSystemService(SensorManager::class.java)

    fun hasProximitySensor(): Boolean = sensors.getDefaultSensor(Sensor.TYPE_PROXIMITY) != null

    // Listeners: Swift's DeviceListener raw values.

    fun setListening(listener: Int, on: Boolean) {
        when (listener) {
            POWER -> if (on) startPower() else stopPower()
            BATTERY -> if (on) startBattery() else stopBattery()
            ORIENTATION -> setSensor(Sensor.TYPE_ACCELEROMETER, accelerometer, on)
            PROXIMITY -> setSensor(Sensor.TYPE_PROXIMITY, proximity, on)
        }
    }

    private val powerSaveReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            DeviceNatives.powerSaveMode(isPowerSaveMode())
        }
    }

    private var thermalListener: Any? = null

    private fun startPower() {
        register(powerSaveReceiver, PowerManager.ACTION_POWER_SAVE_MODE_CHANGED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val listener = PowerManager.OnThermalStatusChangedListener { DeviceNatives.thermalStatus(it) }
            power.addThermalStatusListener(ContextCompat.getMainExecutor(context), listener)
            thermalListener = listener
        }
    }

    private fun stopPower() {
        context.unregisterReceiver(powerSaveReceiver)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            (thermalListener as? PowerManager.OnThermalStatusChangedListener)?.let(power::removeThermalStatusListener)
        }
        thermalListener = null
    }

    private val batteryReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val battery = battery(intent)
            DeviceNatives.battery(battery[0], battery[1], battery[2], battery[3], battery[4] == 1)
        }
    }

    private fun startBattery() = register(batteryReceiver, Intent.ACTION_BATTERY_CHANGED)

    private fun stopBattery() = context.unregisterReceiver(batteryReceiver)

    private fun register(receiver: BroadcastReceiver, action: String) {
        ContextCompat.registerReceiver(context, receiver, IntentFilter(action), ContextCompat.RECEIVER_NOT_EXPORTED)
    }

    private val accelerometer = object : SensorEventListener {
        override fun onSensorChanged(event: SensorEvent) {
            DeviceNatives.accelerometer(event.values[0], event.values[1], event.values[2])
        }

        override fun onAccuracyChanged(sensor: Sensor, accuracy: Int) {}
    }

    private val proximity = object : SensorEventListener {
        override fun onSensorChanged(event: SensorEvent) {
            DeviceNatives.proximity(event.values[0], event.sensor.maximumRange)
        }

        override fun onAccuracyChanged(sensor: Sensor, accuracy: Int) {}
    }

    private fun setSensor(type: Int, listener: SensorEventListener, on: Boolean) {
        if (on) {
            val sensor = sensors.getDefaultSensor(type) ?: return
            sensors.registerListener(listener, sensor, SensorManager.SENSOR_DELAY_UI, HostContext.main)
        } else {
            sensors.unregisterListener(listener)
        }
    }

    private companion object {
        const val POWER = 0
        const val BATTERY = 1
        const val ORIENTATION = 2
        const val PROXIMITY = 3
    }
}

/** What `DeviceSystem`'s listeners hear, for Swift's `DeviceHub`. Main thread. */
object DeviceNatives {

    external fun battery(level: Int, scale: Int, status: Int, plugged: Int, present: Boolean)

    external fun powerSaveMode(enabled: Boolean)

    external fun thermalStatus(status: Int)

    external fun accelerometer(x: Float, y: Float, z: Float)

    external fun proximity(distance: Float, maximumRange: Float)
}
