package org.pureswift.appruntime.contracts

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/**
 * The host's foreground service for Swift's `HostBackground`: it runs for
 * the `ServiceInfo.FOREGROUND_SERVICE_TYPE_*` the manifest declares, with
 * a notification that says what the app is doing. Main thread only.
 */
class BackgroundSystem {

    private val context: Context get() = HostContext.application

    /** The types `HostService` declares; 0 if the manifest has no service. */
    private val declared: Int by lazy {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return@lazy 0
        try {
            context.packageManager.getServiceInfo(ComponentName(context, HostService::class.java), 0).foregroundServiceType
        } catch (error: PackageManager.NameNotFoundException) {
            0
        }
    }

    /** Runs the service for the declared part of `types`, or stops it; the types it runs with. */
    fun run(types: Int): Int {
        val running = types and declared
        val intent = Intent(context, HostService::class.java)
        if (running == 0) {
            context.stopService(intent)
            return 0
        }
        return try {
            ContextCompat.startForegroundService(context, intent.putExtra(HostService.TYPES, running))
            running
        } catch (error: RuntimeException) {
            // ForegroundServiceStartNotAllowedException: the app is in the background.
            Log.w("AppRuntime", "the foreground service can't start: $error")
            0
        }
    }
}

/** The foreground service the packager declares (Documentation/Plan.md §6.2). */
class HostService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val types = intent?.getIntExtra(TYPES, 0) ?: 0
        if (types == 0) {
            stopSelf()
            return START_NOT_STICKY
        }
        try {
            ServiceCompat.startForeground(this, NOTIFICATION, notification(types), types)
        } catch (error: RuntimeException) {
            // A permission the type needs is missing, or the app is in the background.
            Log.w("AppRuntime", "the foreground service can't run: $error")
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun notification(types: Int): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "Background activity", NotificationManager.IMPORTANCE_LOW))
        }
        val location = types and ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION != 0
        val bluetooth = types and ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE != 0
        val text = when {
            location && bluetooth -> "Using your location and Bluetooth devices"
            location -> "Using your location"
            else -> "Connected to Bluetooth devices"
        }
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val open = launch?.let { PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE) }
        val icon = applicationInfo.icon.takeIf { it != 0 } ?: android.R.drawable.ic_dialog_info
        return NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(icon)
            .setContentTitle(applicationInfo.loadLabel(packageManager))
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
    }

    companion object {
        const val TYPES = "org.pureswift.appruntime.types"
        private const val CHANNEL = "org.pureswift.appruntime.background"
        private const val NOTIFICATION = 0x4150
    }
}
