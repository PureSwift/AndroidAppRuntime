package org.pureswift.appruntime

import android.app.Application
import android.content.ComponentCallbacks2
import android.util.Log
import org.pureswift.appruntime.contracts.HostContext
import org.pureswift.appruntime.ui.LazyGridView
import org.pureswift.appruntime.ui.RenderSurface

/**
 * The app's process (Documentation/Plan.md §5): loads `libapp.so`, whose
 * `JNI_OnLoad` sets up swift-java, and owns the renderer's surface, which
 * outlives Activities.
 */
open class AppRuntimeApplication : Application() {

    override fun onCreate() {
        super.onCreate()
        HostContext.application = this
        System.loadLibrary("app")
        LazyGridView.register()
        GraphicsSurface.register()
        WebPageNode.register()
        VideoPlayerNode.register()
        TextSelectionNode.register()
    }

    @Deprecated("Called by the system")
    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        @Suppress("DEPRECATION")
        if (level >= ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW && AppRuntime.started) {
            NativeHost.memoryWarning()
        }
    }
}

/** The process-wide pieces: the surface, and whether the app started. */
object AppRuntime {

    const val TAG = "AppRuntime"

    val surface: RenderSurface by lazy {
        RenderSurface(NativeHost.events).also { surface ->
            surface.log = { Log.w(TAG, it) }
            // adb shell setprop log.tag.AppRuntime DEBUG
            if (Log.isLoggable(TAG, Log.DEBUG)) {
                surface.trace = { trace -> trace.lines().forEach { Log.d(TAG, it) } }
            }
            surface.install()
        }
    }

    /** Whether `rt_main` ran: the guest keeps running across Activities. */
    var started = false
        internal set
}
