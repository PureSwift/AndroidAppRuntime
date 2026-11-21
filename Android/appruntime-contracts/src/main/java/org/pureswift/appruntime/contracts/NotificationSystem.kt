package org.pureswift.appruntime.contracts

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.RemoteInput
import androidx.core.content.ContextCompat
import org.json.JSONArray
import org.json.JSONObject
import java.util.TimeZone

/**
 * Android's notifications for Swift's `AndroidNotificationCenter`
 * (Documentation/Plan.md §6.9): channels, posting, alarms, and what's
 * showing. Swift decides what to post and when; this class only makes the
 * calls. Main thread only.
 *
 * Every notification is posted with its identifier as the tag and [ID] as
 * the id. Its buttons, and a tap on it, open the Activity with the
 * notification in the intent ([open]).
 */
class NotificationSystem {

    private val context: Context get() = HostContext.application

    private val manager: NotificationManager
        get() = context.getSystemService(NotificationManager::class.java)

    private val alarms: AlarmManager
        get() = context.getSystemService(AlarmManager::class.java)

    fun apiLevel(): Int = Build.VERSION.SDK_INT

    /** Whether the user lets the app notify: the app's switch in Settings. */
    fun areEnabled(): Boolean = NotificationManagerCompat.from(context).areNotificationsEnabled()

    /** Whether an alarm arrives on time: the user's setting, from Android 12. */
    fun canScheduleExact(): Boolean =
        Build.VERSION.SDK_INT < 31 || alarms.canScheduleExactAlarms()

    /**
     * Opens the setting for exact alarms; false where there's none to
     * change, or no Activity to open it from.
     */
    fun requestExactTiming(): Boolean {
        if (Build.VERSION.SDK_INT < 31 || alarms.canScheduleExactAlarms()) return false
        val activity = HostContext.activity ?: return false
        return try {
            activity.startActivity(
                Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:" + context.packageName))
            )
            true
        } catch (error: android.content.ActivityNotFoundException) {
            false
        }
    }

    /** The device's time zone, for calendar triggers. */
    fun timeZone(): String = TimeZone.getDefault().id

    /** The app's name, for the default channel. */
    fun appName(): String = context.applicationInfo.loadLabel(context.packageManager).toString()

    /** Where Swift keeps scheduled requests and categories. */
    fun storageDirectory(): String = context.noBackupFilesDir.absolutePath

    /**
     * The categories as channels: `[{id, name, importance, silent}]`. A
     * channel the user has seen keeps their sound and importance; only its
     * name changes.
     */
    fun setChannels(json: String) {
        if (Build.VERSION.SDK_INT < 26) return
        val channels = JSONArray(json)
        for (index in 0 until channels.length()) {
            val channel = channels.getJSONObject(index)
            val made = NotificationChannel(channel.getString("id"), channel.getString("name"), channel.getInt("importance"))
            if (channel.optBoolean("silent")) {
                made.setSound(null, null)
            }
            manager.createNotificationChannel(made)
        }
    }

    /**
     * Shows a notification: `{identifier, channel, title, subtitle, body,
     * thread, number, silent, actions: [{id, title, button?, placeholder?}],
     * record}`. `record` comes back with a tap or a button.
     */
    fun post(json: String): Boolean {
        val notification = JSONObject(json)
        val identifier = notification.getString("identifier")
        val record = notification.getString("record")
        val builder = NotificationCompat.Builder(context, notification.getString("channel"))
            .setSmallIcon(context.applicationInfo.icon.takeIf { it != 0 } ?: android.R.drawable.ic_popup_reminder)
            .setContentTitle(notification.optString("title"))
            .setContentText(notification.optString("body"))
            .setAutoCancel(true)
            .setContentIntent(response(identifier, record, "", false))
        notification.optString("subtitle").takeIf { it.isNotEmpty() }?.let { builder.setSubText(it) }
        notification.optString("thread").takeIf { it.isNotEmpty() }?.let { builder.setGroup(it) }
        if (notification.has("number")) builder.setNumber(notification.getInt("number"))
        if (notification.optBoolean("silent")) builder.setSilent(true)
        val actions = notification.optJSONArray("actions") ?: JSONArray()
        for (index in 0 until actions.length()) {
            val action = actions.getJSONObject(index)
            val id = action.getString("id")
            val text = action.has("button")
            val button = NotificationCompat.Action.Builder(0, action.getString("title"), response(identifier, record, id, text))
            if (text) {
                button.addRemoteInput(RemoteInput.Builder(TEXT).setLabel(action.optString("placeholder")).build())
            }
            builder.addAction(button.build())
        }
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            return false
        }
        manager.notify(identifier, ID, builder.build())
        return true
    }

    /** What opens the Activity with the notification and `action`. */
    private fun response(identifier: String, record: String, action: String, text: Boolean): PendingIntent {
        val intent = Intent(Intent.ACTION_MAIN)
            .setPackage(context.packageName)
            .addCategory(Intent.CATEGORY_LAUNCHER)
            // Distinct per notification and button, so each keeps its own extras.
            .setData(Uri.parse("rt-notification:" + Uri.encode(identifier) + "#" + Uri.encode(action)))
            .putExtra(EXTRA_RECORD, record)
            .putExtra(EXTRA_IDENTIFIER, identifier)
            .putExtra(EXTRA_ACTION, action)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        context.packageManager.getLaunchIntentForPackage(context.packageName)?.component?.let { intent.component = it }
        // A text button's intent must be mutable, for the system to add the text.
        val mutability = if (text && Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else PendingIntent.FLAG_IMMUTABLE
        return PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or mutability)
    }

    /** The identifiers of the app's notifications showing now. */
    fun delivered(): Array<String> =
        manager.activeNotifications.filter { it.id == ID && it.tag != null }.map { it.tag }.toTypedArray()

    /** Takes them out of the list; all of them when `all`. */
    fun removeDelivered(identifiers: Array<String>, all: Boolean) {
        if (all) {
            for (notification in manager.activeNotifications) {
                if (notification.id == ID) manager.cancel(notification.tag, ID)
            }
        } else {
            for (identifier in identifiers) manager.cancel(identifier, ID)
        }
    }

    /**
     * Wakes [NotificationReceiver] for `identifier` at `milliseconds`: on
     * time when the user allows exact alarms, within minutes otherwise.
     */
    fun setAlarm(identifier: String, milliseconds: Long) {
        val pending = alarm(identifier)
        if (canScheduleExact()) {
            alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, milliseconds, pending)
        } else {
            alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, milliseconds, pending)
        }
    }

    fun cancelAlarm(identifier: String) {
        alarms.cancel(alarm(identifier))
    }

    private fun alarm(identifier: String): PendingIntent {
        val intent = Intent(context, NotificationReceiver::class.java)
            .setAction(ACTION_ALARM)
            .setData(Uri.parse("rt-notification:" + Uri.encode(identifier)))
            .putExtra(EXTRA_IDENTIFIER, identifier)
        return PendingIntent.getBroadcast(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    companion object {

        /** The id every notification is posted with; its tag is its identifier. */
        const val ID = 0x5254

        const val ACTION_ALARM = "org.pureswift.appruntime.NOTIFICATION_ALARM"
        const val EXTRA_RECORD = "org.pureswift.appruntime.notification"
        const val EXTRA_IDENTIFIER = "org.pureswift.appruntime.notification.identifier"
        const val EXTRA_ACTION = "org.pureswift.appruntime.notification.action"
        const val TEXT = "org.pureswift.appruntime.notification.text"

        /**
         * A tap on a notification, or one of its buttons, that opened the
         * Activity: true when it was one, and went to Swift. A button's
         * notification is taken out of the list; a tap's goes by itself.
         */
        fun open(intent: Intent): Boolean {
            val record = intent.getStringExtra(EXTRA_RECORD) ?: return false
            val action = intent.getStringExtra(EXTRA_ACTION) ?: ""
            val text = RemoteInput.getResultsFromIntent(intent)?.getCharSequence(TEXT)?.toString()
            if (action.isNotEmpty()) {
                intent.getStringExtra(EXTRA_IDENTIFIER)?.let {
                    HostContext.application.getSystemService(NotificationManager::class.java).cancel(it, ID)
                }
            }
            // Once: a recreated Activity gets the same intent again.
            intent.removeExtra(EXTRA_RECORD)
            NotificationNatives.responded(record, action, text ?: "", text != null)
            return true
        }
    }
}

/**
 * Alarms for scheduled notifications, and the times they must be set
 * again: after a restart, an update, or a change of the clock or time
 * zone. Swift does the work; the process may have started just for this.
 */
class NotificationReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            NotificationSystem.ACTION_ALARM ->
                intent.getStringExtra(NotificationSystem.EXTRA_IDENTIFIER)?.let { NotificationNatives.alarm(it) }
            else -> NotificationNatives.reschedule()
        }
    }
}

/** What Android tells Swift's notifications. Main thread. */
object NotificationNatives {

    /** A tap (`action` empty) or a button, with a text button's text. */
    external fun responded(record: String, action: String, text: String, hasText: Boolean)

    /** A scheduled notification is due. */
    external fun alarm(identifier: String)

    /** The alarms are gone, or due at the wrong time: set them again. */
    external fun reschedule()
}
