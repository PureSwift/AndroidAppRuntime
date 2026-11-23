package org.pureswift.appruntime

import android.graphics.Bitmap
import android.util.LruCache
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import com.pureswift.swiftui.ComposableRegistry
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.pureswift.appruntime.contracts.PhotoSystem
import org.pureswift.appruntime.ui.IRAdapter

/**
 * A `Photo` node (Documentation/Plan.md §6.18): the asset it names, from
 * the system's thumbnails, at the node's size in pixels. The last copy
 * drawn of the asset shows first, if there's one, and a copy at this size
 * replaces it. `fill` crops to the bounds and `fit` shows it all. An asset
 * the app may not see, or one that's gone, draws nothing.
 */
object PhotoNode {

    /** The largest copy drawn of each asset lately. */
    private val drawn = object : LruCache<String, Bitmap>(48 * 1024 * 1024) {
        override fun sizeOf(key: String, value: Bitmap) = value.allocationByteCount
    }

    fun register() {
        ComposableRegistry.register(IRAdapter.PHOTO) { props, _ ->
            val asset = props.string("asset") ?: return@register
            val fit = props.string("scaling") == "fit"
            BoxWithConstraints(Modifier.fillMaxSize().clipToBounds()) {
                val width = if (constraints.hasBoundedWidth) constraints.maxWidth else THUMBNAIL
                val height = if (constraints.hasBoundedHeight) constraints.maxHeight else THUMBNAIL
                var bitmap by remember(asset) { mutableStateOf(drawn.get(asset)) }
                LaunchedEffect(asset, width, height) {
                    val current = bitmap
                    if (current != null && current.width >= width && current.height >= height) return@LaunchedEffect
                    val loaded = withContext(Dispatchers.IO) { PhotoSystem.thumbnail(asset, width, height) }
                    if (loaded != null) {
                        val kept = drawn.get(asset)
                        if (kept == null || kept.width * kept.height < loaded.width * loaded.height) drawn.put(asset, loaded)
                        bitmap = loaded
                    }
                }
                bitmap?.let {
                    Image(
                        it.asImageBitmap(), contentDescription = null, modifier = Modifier.fillMaxSize(),
                        contentScale = if (fit) ContentScale.Fit else ContentScale.Crop,
                    )
                }
            }
        }
    }

    /** A size for a node with no bound on an axis. */
    private const val THUMBNAIL = 512
}
