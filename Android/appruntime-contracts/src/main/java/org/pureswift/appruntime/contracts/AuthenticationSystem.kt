package org.pureswift.appruntime.contracts

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.browser.customtabs.CustomTabsClient
import androidx.browser.customtabs.CustomTabsIntent

/**
 * Sign-in pages for Swift's `AndroidWebAuthenticationPresenter`
 * (Documentation/Plan.md §6.12): the system's browser, in a Custom Tab
 * where the browser has them, over the app's Activity. The provider's
 * redirect to the app's scheme comes back through
 * [AuthenticationRedirectActivity]. Main thread only.
 */
class AuthenticationSystem {

    /**
     * Shows `url`; false when there's no Activity or no browser. With
     * `ephemeral`, a page that keeps no cookies, where the browser can.
     */
    fun present(url: String, ephemeral: Boolean): Boolean {
        val activity = HostContext.activity ?: return false
        val uri = Uri.parse(url)
        val tabs = CustomTabsClient.getPackageName(activity, null)
        return try {
            if (tabs != null) {
                val builder = CustomTabsIntent.Builder().setShareState(CustomTabsIntent.SHARE_STATE_OFF)
                if (ephemeral && CustomTabsClient.isEphemeralBrowsingSupported(activity, tabs)) {
                    builder.setEphemeralBrowsingEnabled(true)
                }
                val intent = builder.build()
                intent.intent.setPackage(tabs)
                intent.launchUrl(activity, uri)
            } else {
                activity.startActivity(Intent(Intent.ACTION_VIEW, uri).addCategory(Intent.CATEGORY_BROWSABLE))
            }
            true
        } catch (error: ActivityNotFoundException) {
            false
        }
    }

    /** Closes the page: the app's Activity comes back over it. */
    fun close() {
        val context = HostContext.application
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        context.startActivity(launch)
    }
}

/**
 * Catches a redirect to one of the app's schemes, which the packager
 * declares for it, hands it to Swift, and brings the app's Activity back
 * over the browser.
 */
class AuthenticationRedirectActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        intent?.dataString?.let { AuthenticationNatives.redirected(it) }
        AuthenticationSystem().close()
        finish()
    }
}

/** What the browser gave back, for Swift. Main thread. */
object AuthenticationNatives {

    external fun redirected(url: String)
}
