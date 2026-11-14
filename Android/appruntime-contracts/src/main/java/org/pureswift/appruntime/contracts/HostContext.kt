package org.pureswift.appruntime.contracts

import android.app.Activity
import android.app.Application
import android.os.Handler
import android.os.Looper
import java.lang.ref.WeakReference

/**
 * What the contract classes need from the shell: the application, the
 * Activity while there is one, and the main thread.
 */
object HostContext {

    /** Set by `AppRuntimeApplication` before `libapp.so` loads. */
    lateinit var application: Application

    private var activityReference: WeakReference<Activity>? = null

    /** The app's Activity, while it's created. */
    var activity: Activity?
        get() = activityReference?.get()
        set(value) {
            activityReference = value?.let(::WeakReference)
        }

    /** Runs `body` on the main thread, where Swift's host runs. */
    val main: Handler by lazy { Handler(Looper.getMainLooper()) }
}
