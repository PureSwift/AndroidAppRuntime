package org.pureswift.appruntime

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import com.pureswift.swiftui.ComposableRegistry
import org.pureswift.appruntime.contracts.GraphicsView
import org.pureswift.appruntime.ui.IRAdapter

/**
 * A `GLSurface` node (Documentation/Plan.md §6.3): a [GraphicsView] in the
 * space SwiftUI gives it, registered with composeui's `ComposableRegistry`
 * as the adapter names it. The node's modifiers wrap it, as for any view.
 */
object GraphicsSurface {

    fun register() {
        ComposableRegistry.register(IRAdapter.GL_SURFACE) { props, _ ->
            val surface = props.int("surface") ?: return@register
            AndroidView(
                factory = { GraphicsView(it) },
                modifier = Modifier.fillMaxSize(),
                update = { it.surfaceID = surface },
            )
        }
    }
}
