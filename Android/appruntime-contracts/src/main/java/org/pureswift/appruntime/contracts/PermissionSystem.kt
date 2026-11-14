package org.pureswift.appruntime.contracts

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat

/**
 * Runtime permissions for Swift's `AndroidPermissions`, which decides what
 * each capability needs and what its status is. Main thread only.
 */
class PermissionSystem {

    private val context: Context get() = HostContext.application

    /** Which permissions the user answered before: Android has no "not determined". */
    private val requested get() = answered(context)

    private val declared: Set<String> by lazy {
        val info = context.packageManager.getPackageInfo(context.packageName, PackageManager.GET_PERMISSIONS)
        info.requestedPermissions?.toSet() ?: emptySet()
    }

    fun apiLevel(): Int = Build.VERSION.SDK_INT

    fun isGranted(permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    fun wasRequested(permission: String): Boolean = requested.getBoolean(permission, false)

    fun isDeclared(permission: String): Boolean = permission in declared

    fun hasFeature(feature: String): Boolean = context.packageManager.hasSystemFeature(feature)

    /** Asks from the Activity, which forwards the answer to [deliver]; false without one. */
    fun request(permissions: Array<String>, id: Int): Boolean {
        val activity = HostContext.activity ?: return false
        ActivityCompat.requestPermissions(activity, permissions, id)
        return true
    }

    companion object {

        private fun answered(context: Context) =
            context.getSharedPreferences("org.pureswift.appruntime.permissions", Context.MODE_PRIVATE)

        /**
         * The Activity's `onRequestPermissionsResult`. The permissions count
         * as answered only now: until then they're still not determined. A
         * dismissed prompt answers nothing.
         */
        fun deliver(id: Int, permissions: Array<String>, results: IntArray) {
            if (results.isNotEmpty()) {
                answered(HostContext.application).edit().apply { permissions.forEach { putBoolean(it, true) } }.apply()
            }
            val granted = BooleanArray(results.size) { results[it] == PackageManager.PERMISSION_GRANTED }
            PermissionNatives.result(id, permissions, granted)
        }
    }
}

/** Answers to [PermissionSystem.request], from the Activity. Main thread. */
object PermissionNatives {

    external fun result(id: Int, permissions: Array<String>, granted: BooleanArray)
}
