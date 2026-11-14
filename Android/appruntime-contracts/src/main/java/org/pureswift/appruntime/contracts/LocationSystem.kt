package org.pureswift.appruntime.contracts

import android.content.Context
import android.hardware.GeomagneticField
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.location.LocationRequest
import android.os.Build
import android.os.Looper
import androidx.core.content.ContextCompat

/**
 * The Location contract's Android side (Swift's `AndroidHostLocation`):
 * `android.location.LocationManager` without Google Play services, and the
 * rotation vector sensor for the heading. Swift picks the provider and
 * the quality. Main thread only.
 */
class LocationSystem {

    private val context: Context get() = HostContext.application

    private val manager: LocationManager get() = context.getSystemService(LocationManager::class.java)

    fun isLocationEnabled(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) manager.isLocationEnabled
        else manager.isProviderEnabled(LocationManager.GPS_PROVIDER) || manager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)

    /** The providers that are on, of fused, gps and network. */
    fun providers(): Array<String> {
        val candidates = mutableListOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) candidates.add(0, LocationManager.FUSED_PROVIDER)
        return candidates.filter { runCatching { manager.isProviderEnabled(it) }.getOrDefault(false) }.toTypedArray()
    }

    fun hasHeadingSensor(): Boolean =
        context.getSystemService(SensorManager::class.java).getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR) != null

    /** Each provider's last fix, eleven doubles each, one after another. */
    fun lastKnown(): DoubleArray {
        val fixes = providers().mapNotNull { provider ->
            try {
                manager.getLastKnownLocation(provider)
            } catch (error: SecurityException) {
                null
            }
        }
        return fixes.flatMap { values(it).asList() }.toDoubleArray()
    }

    fun declination(latitude: Double, longitude: Double, altitude: Double, time: Long): Double =
        GeomagneticField(latitude.toFloat(), longitude.toFloat(), altitude.toFloat(), time).declination.toDouble()

    fun makeSource(handle: Long): LocationSource = LocationSource(handle)

    companion object {

        /** The values Swift's `LocationFixValues` reads, unavailable ones marked as the contract marks them. */
        fun values(location: Location): DoubleArray {
            val vertical = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && location.hasVerticalAccuracy()) location.verticalAccuracyMeters.toDouble() else -1.0
            val speedAccuracy = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && location.hasSpeedAccuracy()) location.speedAccuracyMetersPerSecond.toDouble() else -1.0
            val bearingAccuracy = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && location.hasBearingAccuracy()) location.bearingAccuracyDegrees.toDouble() else -1.0
            @Suppress("DEPRECATION")
            val mock = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) location.isMock else location.isFromMockProvider
            return doubleArrayOf(
                location.latitude,
                location.longitude,
                if (location.hasAltitude()) location.altitude else Double.NaN,
                if (location.hasAccuracy()) location.accuracy.toDouble() else -1.0,
                vertical,
                if (location.hasSpeed()) location.speed.toDouble() else -1.0,
                speedAccuracy,
                if (location.hasBearing()) location.bearing.toDouble() else -1.0,
                bearingAccuracy,
                location.time.toDouble(),
                if (mock) 1.0 else 0.0,
            )
        }
    }
}

/** One Swift manager's location updates and heading. */
class LocationSource(private val handle: Long) {

    private val context: Context get() = HostContext.application

    private val manager: LocationManager get() = context.getSystemService(LocationManager::class.java)

    private val sensors: SensorManager get() = context.getSystemService(SensorManager::class.java)

    private val listener = object : LocationListener {
        override fun onLocationChanged(location: Location) {
            LocationNatives.location(handle, LocationSystem.values(location))
        }

        override fun onProviderDisabled(provider: String) {
            LocationNatives.providerDisabled(handle)
        }

        override fun onProviderEnabled(provider: String) {}

        @Deprecated("Deprecated in Java")
        override fun onStatusChanged(provider: String?, status: Int, extras: android.os.Bundle?) {}
    }

    /** `quality` is a `LocationRequest.QUALITY_*`; false if a permission is missing. */
    fun start(provider: String, quality: Int, interval: Long, minimumDistance: Double): Boolean = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val request = LocationRequest.Builder(interval)
                .setQuality(quality)
                .setMinUpdateDistanceMeters(minimumDistance.toFloat())
                .build()
            manager.requestLocationUpdates(provider, request, ContextCompat.getMainExecutor(context), listener)
        } else {
            manager.requestLocationUpdates(provider, interval, minimumDistance.toFloat(), listener, Looper.getMainLooper())
        }
        true
    } catch (error: SecurityException) {
        false
    } catch (error: IllegalArgumentException) {
        false
    }

    fun stop() {
        manager.removeUpdates(listener)
    }

    private val rotation = FloatArray(9)

    private val orientation = FloatArray(3)

    private var accuracy = SensorManager.SENSOR_STATUS_UNRELIABLE

    private val headingListener = object : SensorEventListener {
        override fun onSensorChanged(event: SensorEvent) {
            SensorManager.getRotationMatrixFromVector(rotation, event.values)
            SensorManager.getOrientation(rotation, orientation)
            val azimuth = Math.toDegrees(orientation[0].toDouble())
            val estimate = if (event.values.size > 4) event.values[4].toDouble() else -1.0
            LocationNatives.heading(handle, azimuth, accuracy, estimate, System.currentTimeMillis())
        }

        override fun onAccuracyChanged(sensor: Sensor, accuracy: Int) {
            this@LocationSource.accuracy = accuracy
        }
    }

    fun startHeading(): Boolean {
        val sensor = sensors.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR) ?: return false
        accuracy = SensorManager.SENSOR_STATUS_ACCURACY_MEDIUM
        return sensors.registerListener(headingListener, sensor, SensorManager.SENSOR_DELAY_UI, HostContext.main)
    }

    fun stopHeading() {
        sensors.unregisterListener(headingListener)
    }
}

/** What each `LocationSource` hears, for Swift's `LocationHub`. Main thread. */
object LocationNatives {

    external fun location(handle: Long, values: DoubleArray)

    external fun providerDisabled(handle: Long)

    external fun heading(handle: Long, azimuth: Double, status: Int, estimate: Double, timestamp: Long)
}
