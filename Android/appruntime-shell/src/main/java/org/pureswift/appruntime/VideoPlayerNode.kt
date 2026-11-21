package org.pureswift.appruntime

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import com.pureswift.swiftui.ComposableRegistry
import org.pureswift.appruntime.contracts.MediaSystem
import org.pureswift.appruntime.ui.IRAdapter

/**
 * A `VideoPlayer` node (Documentation/Plan.md §6.10): the player it names,
 * in Media3's [PlayerView], with the platform's controls unless the node
 * says `none`. When the node goes, the view lets the player go, and the
 * player keeps playing and its place.
 */
object VideoPlayerNode {

    fun register() {
        ComposableRegistry.register(IRAdapter.VIDEO_PLAYER) { props, _ ->
            val id = props.int("player") ?: return@register
            val scaling = props.string("scaling")
            val controls = props.string("controls") != "none"
            AndroidView(
                factory = { PlayerView(it) },
                modifier = Modifier.fillMaxSize(),
                update = { view ->
                    view.player = MediaSystem.player(id)
                    view.useController = controls
                    view.resizeMode = if (scaling == "fill") AspectRatioFrameLayout.RESIZE_MODE_ZOOM else AspectRatioFrameLayout.RESIZE_MODE_FIT
                },
                onRelease = { it.player = null },
            )
        }
    }
}
