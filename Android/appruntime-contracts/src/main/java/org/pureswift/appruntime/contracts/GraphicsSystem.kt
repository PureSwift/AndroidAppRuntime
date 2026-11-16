package org.pureswift.appruntime.contracts

import android.content.Context
import android.graphics.Rect
import android.graphics.SurfaceTexture
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.Surface
import android.view.TextureView
import android.view.View
import android.view.ViewConfiguration

/**
 * Where a surface draws (Documentation/Plan.md §6.3): the player puts one
 * where a `GLSurface` node is. Swift's `SurfaceHub` draws in its window on
 * the main thread with EGL, and gets its input, raw, through
 * [GraphicsNatives].
 *
 * A TextureView composes like any other view, so the views around it can
 * layer over it and clip it, as SwiftUI lays them out.
 */
class GraphicsView(context: Context) : TextureView(context), TextureView.SurfaceTextureListener {

    /** The surface it shows: the `GLSurface` node's `surface` prop. */
    var surfaceID: Int = 0
        set(value) {
            if (value == field) return
            detachWindow()
            if (views[field] === this) views.remove(field)
            field = value
            if (isAttachedToWindow) views[value] = this
            attachWindow()
        }

    /** The window Swift draws in, while the texture is available. */
    private var window: Surface? = null

    /** The surface the window was given to, or 0. */
    private var attached = 0

    private var shown = true

    /** Where the mouse was, for button events while it's captured. */
    private var lastX = 0f
    private var lastY = 0f

    init {
        surfaceTextureListener = this
        isFocusable = true
        isFocusableInTouchMode = true
        // GL draws pixels TalkBack can't read; the node's accessibility
        // modifiers label the view around it.
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    private val scale: Float get() = resources.displayMetrics.density

    private fun attachWindow() {
        val window = window ?: return
        if (surfaceID == 0 || attached != 0) return
        attached = surfaceID
        GraphicsNatives.attach(attached, window, width, height, scale)
        if (!shown) GraphicsNatives.visible(attached, false)
        if (isFocused && hasWindowFocus()) GraphicsNatives.focus(attached, true)
    }

    private fun detachWindow() {
        if (attached == 0) return
        GraphicsNatives.detach(attached)
        attached = 0
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        if (surfaceID != 0) views[surfaceID] = this
    }

    override fun onDetachedFromWindow() {
        if (views[surfaceID] === this) views.remove(surfaceID)
        super.onDetachedFromWindow()
    }

    // MARK: The window

    override fun onSurfaceTextureAvailable(texture: SurfaceTexture, width: Int, height: Int) {
        window = Surface(texture)
        attachWindow()
    }

    override fun onSurfaceTextureSizeChanged(texture: SurfaceTexture, width: Int, height: Int) {
        if (attached != 0) GraphicsNatives.resize(attached, width, height, scale)
    }

    override fun onSurfaceTextureDestroyed(texture: SurfaceTexture): Boolean {
        // EGL lets go of the window before the texture goes.
        detachWindow()
        window?.release()
        window = null
        return true
    }

    override fun onSurfaceTextureUpdated(texture: SurfaceTexture) {}

    override fun onVisibilityAggregated(isVisible: Boolean) {
        super.onVisibilityAggregated(isVisible)
        shown = isVisible
        if (attached != 0) GraphicsNatives.visible(attached, isVisible)
    }

    // MARK: Pointers

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (attached == 0) return false
        if (event.actionMasked == MotionEvent.ACTION_DOWN && !isFocused) requestFocus()
        send(event)
        return true
    }

    override fun onHoverEvent(event: MotionEvent): Boolean {
        if (attached == 0) return super.onHoverEvent(event)
        send(event)
        return true
    }

    override fun onGenericMotionEvent(event: MotionEvent): Boolean {
        if (attached == 0) return super.onGenericMotionEvent(event)
        when (event.actionMasked) {
            MotionEvent.ACTION_SCROLL -> {
                val configuration = ViewConfiguration.get(context)
                GraphicsNatives.scroll(
                    attached,
                    event.getAxisValue(MotionEvent.AXIS_HSCROLL), event.getAxisValue(MotionEvent.AXIS_VSCROLL),
                    configuration.scaledHorizontalScrollFactor, configuration.scaledVerticalScrollFactor,
                )
            }
            MotionEvent.ACTION_BUTTON_PRESS, MotionEvent.ACTION_BUTTON_RELEASE -> send(event)
            else -> return super.onGenericMotionEvent(event)
        }
        return true
    }

    /** Each pointer of `event`, with whether its action is about that one. */
    private fun send(event: MotionEvent) {
        val action = event.actionMasked
        for (index in 0 until event.pointerCount) {
            GraphicsNatives.pointer(
                attached, action, index == event.actionIndex, event.getPointerId(index), event.getToolType(index),
                event.getX(index), event.getY(index), event.buttonState, event.eventTime,
            )
        }
        lastX = event.x
        lastY = event.y
    }

    // MARK: Keys and focus

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean = key(event) || super.onKeyDown(keyCode, event)

    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean = key(event) || super.onKeyUp(keyCode, event)

    private fun key(event: KeyEvent): Boolean =
        attached != 0 && GraphicsNatives.key(
            attached, event.action, event.keyCode, event.scanCode, event.metaState, event.repeatCount, event.eventTime,
        )

    override fun onFocusChanged(gainFocus: Boolean, direction: Int, previouslyFocusedRect: Rect?) {
        super.onFocusChanged(gainFocus, direction, previouslyFocusedRect)
        reportFocus()
    }

    override fun onWindowFocusChanged(hasWindowFocus: Boolean) {
        super.onWindowFocusChanged(hasWindowFocus)
        reportFocus()
    }

    /** Keys come only while the view is focused in a focused window. */
    private fun reportFocus() {
        if (attached != 0) GraphicsNatives.focus(attached, isFocused && hasWindowFocus())
    }

    // MARK: Pointer capture

    /** Asks for the mouse, or lets it go; whether capture was asked for. */
    fun capture(captured: Boolean): Boolean {
        if (!captured) {
            releasePointerCapture()
            return false
        }
        if (attached == 0 || !hasWindowFocus() || !hasMouse()) return false
        requestPointerCapture()
        return true
    }

    private fun hasMouse(): Boolean =
        InputDevice.getDeviceIds().any { InputDevice.getDevice(it)?.supportsSource(InputDevice.SOURCE_MOUSE) == true }

    override fun onPointerCaptureChange(hasCapture: Boolean) {
        super.onPointerCaptureChange(hasCapture)
        if (attached != 0) GraphicsNatives.capture(attached, hasCapture)
    }

    override fun onCapturedPointerEvent(event: MotionEvent): Boolean {
        if (attached == 0) return false
        when (event.actionMasked) {
            // A relative mouse's x and y are how far it moved.
            MotionEvent.ACTION_MOVE -> GraphicsNatives.relative(attached, event.x, event.y, event.eventTime)
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP,
            MotionEvent.ACTION_BUTTON_PRESS, MotionEvent.ACTION_BUTTON_RELEASE -> GraphicsNatives.pointer(
                attached, event.actionMasked, true, 0, MotionEvent.TOOL_TYPE_MOUSE, lastX, lastY, event.buttonState, event.eventTime,
            )
        }
        return true
    }

    internal companion object {
        /** The view showing each surface, for pointer capture. */
        val views = HashMap<Int, GraphicsView>()
    }
}

/** Pointer capture, which Swift asks of the view showing a surface. */
class GraphicsSystem {

    fun setPointerCaptured(surface: Int, captured: Boolean): Boolean =
        GraphicsView.views[surface]?.capture(captured) ?: false
}

/** What [GraphicsView]s report to Swift's `SurfaceHub`, on the main thread. */
object GraphicsNatives {

    external fun attach(surface: Int, window: Surface, width: Int, height: Int, scale: Float)

    external fun resize(surface: Int, width: Int, height: Int, scale: Float)

    external fun detach(surface: Int)

    external fun visible(surface: Int, visible: Boolean)

    external fun pointer(
        surface: Int, action: Int, isActionPointer: Boolean, pointer: Int, toolType: Int,
        x: Float, y: Float, buttonState: Int, eventTime: Long,
    )

    external fun scroll(surface: Int, horizontal: Float, vertical: Float, horizontalFactor: Float, verticalFactor: Float)

    external fun key(surface: Int, action: Int, keyCode: Int, scanCode: Int, metaState: Int, repeatCount: Int, eventTime: Long): Boolean

    external fun focus(surface: Int, focused: Boolean)

    external fun capture(surface: Int, captured: Boolean)

    external fun relative(surface: Int, x: Float, y: Float, eventTime: Long)
}
