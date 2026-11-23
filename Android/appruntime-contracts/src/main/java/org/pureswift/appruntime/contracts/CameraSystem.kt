package org.pureswift.appruntime.contracts

import android.annotation.SuppressLint
import android.content.Context
import android.content.MutableContextWrapper
import android.graphics.BitmapFactory
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.media.ExifInterface
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.Surface
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.FocusMeteringAction
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.FileOutputOptions
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoRecordEvent
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import java.io.File

/**
 * The `CameraCapture` contract's Android side (Documentation/Plan.md §6.19):
 * a camera per guest `Camera`, over CameraX, with its `PreviewView` made off
 * screen. Swift's `AndroidCameraEngine` asks; what the camera does comes
 * back through [CameraNatives]; [CameraPreviewFrame] shows a camera where a
 * `CameraPreview` node names it. Main thread only.
 *
 * Each camera binds a preview, a photo capture and a video capture to a
 * lifecycle of its own, which is resumed while the camera is on. One is on
 * at a time: Swift's `HostCameraCapture` turns the other off first.
 */
class CameraSystem {

    /** The device's cameras: bits, 1 back, 2 front, 4 external. */
    fun positions(): Int {
        val manager = HostContext.application.getSystemService(Context.CAMERA_SERVICE) as? CameraManager ?: return 0
        var bits = 0
        try {
            for (id in manager.cameraIdList) {
                bits = bits or when (manager.getCameraCharacteristics(id).get(CameraCharacteristics.LENS_FACING)) {
                    CameraCharacteristics.LENS_FACING_BACK -> 1
                    CameraCharacteristics.LENS_FACING_FRONT -> 2
                    CameraCharacteristics.LENS_FACING_EXTERNAL -> 4
                    else -> 0
                }
            }
        } catch (error: Exception) {
        }
        return bits
    }

    fun make(id: Int) {
        cameras[id] = HostCamera(id)
    }

    fun destroy(id: Int) {
        cameras.remove(id)?.destroy()
    }

    fun start(id: Int, position: Int) {
        cameras[id]?.start(position)
    }

    fun stop(id: Int) {
        cameras[id]?.stop()
    }

    fun setZoom(id: Int, factor: Double) {
        cameras[id]?.camera?.cameraControl?.setZoomRatio(factor.toFloat())
    }

    /** 0 off, 1 on, 2 auto. */
    fun setFlashMode(id: Int, mode: Int) {
        cameras[id]?.flashMode = when (mode) {
            1 -> ImageCapture.FLASH_MODE_ON
            2 -> ImageCapture.FLASH_MODE_AUTO
            else -> ImageCapture.FLASH_MODE_OFF
        }
    }

    /** Answered by [CameraNatives.photo] with `request`. */
    fun capturePhoto(id: Int, path: String, request: Int) {
        val camera = cameras[id] ?: return CameraNatives.photo(id, request, 0, 0, NOT_RUNNING)
        camera.capturePhoto(path, request)
    }

    /** Answered by [CameraNatives.recordingStarted], and later [CameraNatives.recordingFinished]. */
    fun startRecording(id: Int, path: String, audio: Boolean, request: Int) {
        val camera = cameras[id] ?: return CameraNatives.recordingStarted(id, request, NOT_RUNNING)
        camera.startRecording(path, audio, request)
    }

    fun stopRecording(id: Int) {
        cameras[id]?.stopRecording()
    }

    internal companion object {
        // CameraError raw values; `unknown` as -1, since 0 is no error.
        const val UNKNOWN = -1
        const val UNAVAILABLE = 3
        const val NOT_RUNNING = 4
        const val BUSY = 5
        const val INTERRUPTED = 6
        const val WRITE_FAILED = 7

        /** Every camera, by the identifier its `CameraPreview` node carries. */
        val cameras = HashMap<Int, HostCamera>()
    }
}

/** One camera: its use cases, bound while it's on, and its preview's view. */
internal class HostCamera(val id: Int) : LifecycleOwner {

    private val registry = LifecycleRegistry(this).apply { currentState = Lifecycle.State.CREATED }

    override val lifecycle: Lifecycle get() = registry

    /** Lets the view's context follow the Activity. */
    private val context = MutableContextWrapper(HostContext.application)

    private val main = ContextCompat.getMainExecutor(HostContext.application)

    val view: PreviewView = PreviewView(context).apply {
        // A TextureView, which Compose and screenshots show as any view.
        implementationMode = PreviewView.ImplementationMode.COMPATIBLE
    }

    var camera: Camera? = null
        private set

    private var imageCapture: ImageCapture? = null

    private var videoCapture: VideoCapture<Recorder>? = null

    private var recording: Recording? = null

    /** Counts starts and stops, so a start that finishes late knows it's stale. */
    private var generation = 0

    var flashMode = ImageCapture.FLASH_MODE_OFF
        set(value) {
            field = value
            imageCapture?.flashMode = value
        }

    init {
        gestures()
    }

    fun attach(activity: Context) {
        context.baseContext = activity
    }

    // MARK: On and off

    fun start(position: Int) {
        val generation = ++generation
        val future = ProcessCameraProvider.getInstance(HostContext.application)
        future.addListener({
            if (generation != this.generation) return@addListener
            val provider = try {
                future.get()
            } catch (error: Exception) {
                return@addListener CameraNatives.failed(id, CameraSystem.UNAVAILABLE)
            }
            val selector = when (position) {
                2 -> CameraSelector.DEFAULT_FRONT_CAMERA
                4 -> CameraSelector.Builder().addCameraFilter { infos -> infos.filter { it.lensFacing == CameraSelector.LENS_FACING_EXTERNAL } }.build()
                else -> CameraSelector.DEFAULT_BACK_CAMERA
            }
            val preview = Preview.Builder().build().also { it.surfaceProvider = view.surfaceProvider }
            val imageCapture = ImageCapture.Builder()
                .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
                .setFlashMode(flashMode)
                .build()
            val videoCapture = VideoCapture.withOutput(Recorder.Builder().build())
            try {
                provider.unbindAll()
                registry.currentState = Lifecycle.State.RESUMED
                val camera = provider.bindToLifecycle(this, selector, preview, imageCapture, videoCapture)
                this.camera = camera
                this.imageCapture = imageCapture
                this.videoCapture = videoCapture
                val zoom = camera.cameraInfo.zoomState.value
                CameraNatives.started(id, (zoom?.minZoomRatio ?: 1f).toDouble(), (zoom?.maxZoomRatio ?: 1f).toDouble(), camera.cameraInfo.hasFlashUnit())
            } catch (error: IllegalArgumentException) {
                // No camera there.
                release(provider)
                CameraNatives.failed(id, CameraSystem.UNAVAILABLE)
            } catch (error: Exception) {
                release(provider)
                CameraNatives.failed(id, CameraSystem.UNKNOWN)
            }
        }, main)
    }

    fun stop() {
        generation++
        recording?.stop()
        val future = ProcessCameraProvider.getInstance(HostContext.application)
        if (future.isDone) release(future.get())
        camera = null
        imageCapture = null
        videoCapture = null
        registry.currentState = Lifecycle.State.CREATED
    }

    /** Unbinds the use cases: one camera is on at a time, so all of them. */
    private fun release(provider: ProcessCameraProvider) {
        provider.unbindAll()
    }

    fun destroy() {
        stop()
        registry.currentState = Lifecycle.State.DESTROYED
        (view.parent as? ViewGroup)?.removeView(view)
    }

    // MARK: Photos

    fun capturePhoto(path: String, request: Int) {
        val capture = imageCapture ?: return CameraNatives.photo(id, request, 0, 0, CameraSystem.NOT_RUNNING)
        capture.targetRotation = rotation()
        val file = File(path)
        capture.takePicture(ImageCapture.OutputFileOptions.Builder(file).build(), main, object : ImageCapture.OnImageSavedCallback {
            override fun onImageSaved(results: ImageCapture.OutputFileResults) {
                val (width, height) = uprightSize(file)
                CameraNatives.photo(id, request, width, height, 0)
            }

            override fun onError(error: ImageCaptureException) {
                val code = when (error.imageCaptureError) {
                    ImageCapture.ERROR_FILE_IO -> CameraSystem.WRITE_FAILED
                    ImageCapture.ERROR_CAMERA_CLOSED -> CameraSystem.INTERRUPTED
                    else -> CameraSystem.UNKNOWN
                }
                CameraNatives.photo(id, request, 0, 0, code)
            }
        })
    }

    /** The JPEG's size as it displays, after its orientation. */
    private fun uprightSize(file: File): Pair<Int, Int> {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        val orientation = try {
            ExifInterface(file.path).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
        } catch (error: Exception) {
            ExifInterface.ORIENTATION_NORMAL
        }
        val turned = orientation in listOf(
            ExifInterface.ORIENTATION_ROTATE_90, ExifInterface.ORIENTATION_ROTATE_270,
            ExifInterface.ORIENTATION_TRANSPOSE, ExifInterface.ORIENTATION_TRANSVERSE,
        )
        return if (turned) bounds.outHeight to bounds.outWidth else bounds.outWidth to bounds.outHeight
    }

    // MARK: Video

    @SuppressLint("MissingPermission")
    fun startRecording(path: String, audio: Boolean, request: Int) {
        val video = videoCapture ?: return CameraNatives.recordingStarted(id, request, CameraSystem.NOT_RUNNING)
        if (recording != null) return CameraNatives.recordingStarted(id, request, CameraSystem.BUSY)
        video.targetRotation = rotation()
        var pending = video.output.prepareRecording(HostContext.application, FileOutputOptions.Builder(File(path)).build())
        // Swift checked the capability and the user's leave.
        if (audio) pending = pending.withAudioEnabled()
        var began = false
        recording = try {
            pending.start(main) { event ->
                when (event) {
                    is VideoRecordEvent.Start -> {
                        began = true
                        CameraNatives.recordingStarted(id, request, 0)
                    }
                    is VideoRecordEvent.Finalize -> {
                        recording = null
                        val code = when (event.error) {
                            VideoRecordEvent.Finalize.ERROR_NONE,
                            VideoRecordEvent.Finalize.ERROR_FILE_SIZE_LIMIT_REACHED,
                            VideoRecordEvent.Finalize.ERROR_DURATION_LIMIT_REACHED -> 0
                            VideoRecordEvent.Finalize.ERROR_INSUFFICIENT_STORAGE,
                            VideoRecordEvent.Finalize.ERROR_INVALID_OUTPUT_OPTIONS -> CameraSystem.WRITE_FAILED
                            VideoRecordEvent.Finalize.ERROR_SOURCE_INACTIVE -> CameraSystem.INTERRUPTED
                            else -> CameraSystem.UNKNOWN
                        }
                        if (began) {
                            val seconds = event.recordingStats.recordedDurationNanos / 1e9
                            CameraNatives.recordingFinished(id, seconds, "video/mp4", code)
                        } else {
                            CameraNatives.recordingStarted(id, request, if (code == 0) CameraSystem.UNKNOWN else code)
                        }
                    }
                }
            }
        } catch (error: Exception) {
            CameraNatives.recordingStarted(id, request, CameraSystem.UNKNOWN)
            null
        }
    }

    fun stopRecording() {
        recording?.stop()
    }

    // MARK: The preview's gestures

    /** A tap focuses and meters there; a pinch zooms, and Swift hears of it. */
    @SuppressLint("ClickableViewAccessibility")
    private fun gestures() {
        val taps = GestureDetector(view.context, object : GestureDetector.SimpleOnGestureListener() {
            override fun onSingleTapUp(event: MotionEvent): Boolean {
                val camera = camera ?: return false
                val point = view.meteringPointFactory.createPoint(event.x, event.y)
                camera.cameraControl.startFocusAndMetering(FocusMeteringAction.Builder(point).build())
                return true
            }
        })
        val pinches = ScaleGestureDetector(view.context, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
            override fun onScale(detector: ScaleGestureDetector): Boolean {
                val camera = camera ?: return false
                val zoom = camera.cameraInfo.zoomState.value ?: return false
                val ratio = (zoom.zoomRatio * detector.scaleFactor).coerceIn(zoom.minZoomRatio, zoom.maxZoomRatio)
                camera.cameraControl.setZoomRatio(ratio)
                CameraNatives.zoomChanged(id, ratio.toDouble())
                return true
            }
        })
        view.setOnTouchListener { _, event ->
            pinches.onTouchEvent(event)
            if (!pinches.isInProgress) taps.onTouchEvent(event)
            true
        }
    }

    private fun rotation(): Int = view.display?.rotation ?: Surface.ROTATION_0
}

/**
 * Where a `CameraPreview` node shows the camera it names: that camera's
 * `PreviewView`, filling or fitting the frame. When the node goes, the
 * camera stays on.
 */
class CameraPreviewFrame(context: Context) : FrameLayout(context) {

    /** The camera shown: the node's `camera` prop, or 0 for none. */
    var camera: Int = 0
        set(value) {
            if (value == field) return
            release()
            field = value
            show()
        }

    var fits: Boolean = false
        set(value) {
            field = value
            preview?.scaleType = if (value) PreviewView.ScaleType.FIT_CENTER else PreviewView.ScaleType.FILL_CENTER
        }

    private val preview: PreviewView? get() = CameraSystem.cameras[camera]?.view

    private fun show() {
        val host = CameraSystem.cameras[camera] ?: return
        val view = host.view
        (view.parent as? ViewGroup)?.removeView(view)
        host.attach(context)
        view.scaleType = if (fits) PreviewView.ScaleType.FIT_CENTER else PreviewView.ScaleType.FILL_CENTER
        addView(view, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
    }

    private fun release() {
        val view = preview ?: return
        if (view.parent === this) removeView(view)
    }
}

/** What the cameras report to Swift's `CameraHub`, on the main thread. */
object CameraNatives {

    /** The camera is on, at a zoom of 1. */
    external fun started(id: Int, minimumZoom: Double, maximumZoom: Double, hasFlash: Boolean)

    /** The camera couldn't be turned on: a `CameraError`, -1 for `unknown`. */
    external fun failed(id: Int, error: Int)

    /** The user pinched the preview. */
    external fun zoomChanged(id: Int, factor: Double)

    /** A photo is written, upright, or failed: 0, or a `CameraError`. */
    external fun photo(id: Int, request: Int, width: Int, height: Int, error: Int)

    /** Recording began, or couldn't: 0, or a `CameraError`. */
    external fun recordingStarted(id: Int, request: Int, error: Int)

    /** A recording's file is whole: 0, or why it was cut short. */
    external fun recordingFinished(id: Int, duration: Double, mimeType: String, error: Int)
}
