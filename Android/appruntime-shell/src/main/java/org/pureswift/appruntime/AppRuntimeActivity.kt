package org.pureswift.appruntime

import android.content.Intent
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.unit.dp
import com.pureswift.swiftui.Render
import org.pureswift.appruntime.contracts.DocumentSystem
import org.pureswift.appruntime.contracts.HostContext
import org.pureswift.appruntime.contracts.NotificationSystem
import org.pureswift.appruntime.contracts.PermissionSystem
import org.pureswift.appruntime.contracts.PhotoSystem

/**
 * The app's one Activity (Documentation/Plan.md §5): starts the guest with
 * the app's keys from `assets/rt/Info.plist`, shows the renderer's surface,
 * and reports the lifecycle, URLs, files it's opened with, pickers' results,
 * taps on notifications and the back gesture.
 *
 * It declares `configChanges` for rotation, dark mode and locale, so those
 * don't restart it; if the system recreates it anyway, the guest keeps
 * running and the new Activity shows the same surface.
 */
open class AppRuntimeActivity : ComponentActivity() {

    private var error: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        HostContext.activity = this
        val surface = AppRuntime.surface
        surface.dark = isDark(resources.configuration)
        error = startApp()
        setContent { Root(error) }
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                // The guest's NavStack goes back; otherwise the system does.
                if (!AppRuntime.surface.goBack()) {
                    isEnabled = false
                    onBackPressedDispatcher.onBackPressed()
                    isEnabled = true
                }
            }
        })
        if (savedInstanceState == null) {
            openURL(intent)
        }
    }

    private fun startApp(): String? = AppRuntime.start(this, background = false)

    @OptIn(ExperimentalComposeUiApi::class)
    @Composable
    private fun Root(error: String?) {
        val dark = isSystemInDarkTheme()
        val context = LocalContext.current
        val colors = when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
            dark -> darkColorScheme()
            else -> lightColorScheme()
        }
        MaterialTheme(colorScheme = colors) {
            Surface(
                modifier = Modifier
                    .fillMaxSize()
                    // accessibilityIdentifier becomes a resource ID for UI Automator.
                    .semantics { testTagsAsResourceId = true }
                    .safeDrawingPadding(),
            ) {
                if (error != null) {
                    Text(error, modifier = Modifier.padding(24.dp))
                } else {
                    AppRuntime.surface.store.root?.let { Render(it) }
                }
            }
        }
    }

    override fun onStart() {
        super.onStart()
        if (AppRuntime.started) NativeHost.setState(STATE_INACTIVE)
    }

    override fun onResume() {
        super.onResume()
        if (AppRuntime.started) NativeHost.setState(STATE_ACTIVE)
    }

    override fun onPause() {
        if (AppRuntime.started) NativeHost.setState(STATE_INACTIVE)
        super.onPause()
    }

    override fun onStop() {
        if (AppRuntime.started) NativeHost.setState(STATE_BACKGROUND)
        super.onStop()
    }

    override fun onDestroy() {
        if (HostContext.activity === this) HostContext.activity = null
        super.onDestroy()
    }

    @Deprecated("The permission requests use ActivityCompat")
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray) {
        @Suppress("DEPRECATION")
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (AppRuntime.started) PermissionSystem.deliver(requestCode, permissions, grantResults)
    }

    @Deprecated("The document pickers use startActivityForResult")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (AppRuntime.started && PhotoSystem.deliver(requestCode, resultCode)) return
        if (AppRuntime.started) DocumentSystem.deliver(requestCode, resultCode, data)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        openURL(intent)
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        AppRuntime.surface.dark = isDark(newConfig)
        if (AppRuntime.started) NativeHost.setLanguages(languages())
    }

    /** A notification's tap or button goes to the guest's notifications, a file to its documents, any other URL to the app. */
    private fun openURL(intent: Intent?) {
        if (intent != null && AppRuntime.started && NotificationSystem.open(intent)) return
        if (intent != null && AppRuntime.started && DocumentSystem.open(intent)) return
        val url = intent?.takeIf { it.action == Intent.ACTION_VIEW }?.dataString ?: return
        if (AppRuntime.started && !NativeHost.open(url)) {
            Log.i(AppRuntime.TAG, "the app didn't open $url")
        }
    }

    private fun isDark(configuration: Configuration): Boolean =
        configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES

    private fun languages(): Array<String> = AppRuntime.languages()

    private companion object {
        // ApplicationState's raw values.
        const val STATE_ACTIVE = 0
        const val STATE_INACTIVE = 1
        const val STATE_BACKGROUND = 2
    }
}
