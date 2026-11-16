package org.pureswift.appruntime

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import com.pureswift.swiftui.ComposableRegistry
import org.pureswift.appruntime.contracts.WebPageView
import org.pureswift.appruntime.ui.IRAdapter

/**
 * A `WebView` node (Documentation/Plan.md §6.4): the page it names, in a
 * [WebPageView] that takes the space SwiftUI offers. When the node goes,
 * the page leaves the view and stays loaded.
 */
object WebPageNode {

    fun register() {
        ComposableRegistry.register(IRAdapter.WEB_VIEW) { props, _ ->
            val page = props.int("page") ?: return@register
            AndroidView(
                factory = { WebPageView(it) },
                modifier = Modifier.fillMaxSize(),
                update = { it.page = page },
                onRelease = { it.page = 0 },
            )
        }
    }
}
