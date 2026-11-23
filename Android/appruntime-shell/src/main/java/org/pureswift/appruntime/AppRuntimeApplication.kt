package org.pureswift.appruntime

import android.app.Application
import android.content.ComponentCallbacks2
import android.content.Context
import android.os.LocaleList
import android.util.Log
import org.pureswift.appruntime.contracts.BackgroundTaskSystem
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
        TextEditorNode.register()
        PhotoNode.register()
        CameraPreviewNode.register()
        TextSelectionNode.register()
        // A task WorkManager runs while the app is closed starts it here,
        // with no window (Documentation/Plan.md §6.17).
        BackgroundTaskSystem.startApp = { AppRuntime.start(this, background = true) }
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

    /**
     * Starts the app with the keys in `assets/rt/Info.plist`: null, or why
     * it couldn't. Once it's running, an Activity gets the same app, and
     * shows the surface it has drawn to. `background`: the system started
     * it to run a task, with no window, and it's in the background until an
     * Activity shows it (Documentation/Plan.md §6.17).
     */
    fun start(context: Context, background: Boolean): String? {
        if (started && background) return null
        val info = try {
            context.assets.open("rt/Info.plist").use { it.readBytes() }
        } catch (error: java.io.IOException) {
            return "This APK has no assets/rt/Info.plist."
        }
        val result = NativeHost.start(info, languages(), surface, background)
        if (result.isNotEmpty()) {
            Log.e(TAG, result)
            return result
        }
        started = true
        return null
    }

    /** The user's languages, as BCP 47 tags. */
    fun languages(): Array<String> {
        val locales = LocaleList.getDefault()
        return Array(locales.size()) { locales[it].toLanguageTag() }
    }
}
