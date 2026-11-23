package org.pureswift.appruntime

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import com.pureswift.swiftui.ComposableRegistry
import org.pureswift.appruntime.contracts.CameraPreviewFrame
import org.pureswift.appruntime.ui.IRAdapter

/**
 * A `CameraPreview` node (Documentation/Plan.md §6.19): the camera it names,
 * in a [CameraPreviewFrame] that takes the space SwiftUI offers, filling and
 * cropping or fitting. A tap focuses and a pinch zooms, in the preview
 * itself. When the node goes, the camera stays on.
 */
object CameraPreviewNode {

    fun register() {
        ComposableRegistry.register(IRAdapter.CAMERA_PREVIEW) { props, _ ->
            val camera = props.int("camera") ?: return@register
            val fits = props.string("scaling") == "fit"
            AndroidView(
                factory = { CameraPreviewFrame(it) },
                modifier = Modifier.fillMaxSize(),
                update = { view ->
                    view.camera = camera
                    view.fits = fits
                },
                onRelease = { it.camera = 0 },
            )
        }
    }
}
