package org.pureswift.appruntime.contracts

import android.content.Context
import android.content.SharedPreferences

/**
 * The app's own settings for Swift's `AndroidDefaultsStorage`: one
 * `SharedPreferences` file, apart from anything else the app keeps, holding
 * strings under keys Swift marks with their kind. Edits are applied, which
 * writes in the background; Android waits for the write when the Activity
 * stops. Main thread only.
 */
class DefaultsSystem {

    private val preferences: SharedPreferences =
        HostContext.application.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun contains(key: String): Boolean = preferences.contains(key)

    /** The string at `key`; empty when there's none or it isn't a string. */
    fun string(key: String): String = (preferences.all[key] as? String) ?: ""

    fun set(key: String, value: String, removing: String) {
        preferences.edit().putString(key, value).remove(removing).apply()
    }

    fun remove(keys: Array<String>) {
        val editor = preferences.edit()
        for (key in keys) {
            editor.remove(key)
        }
        editor.apply()
    }

    fun keys(): Array<String> = preferences.all.keys.toTypedArray()

    companion object {
        /** `shared_prefs/org.pureswift.appruntime.defaults.xml`. */
        const val FILE = "org.pureswift.appruntime.defaults"
    }
}
