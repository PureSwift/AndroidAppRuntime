package org.pureswift.appruntime

import org.pureswift.appruntime.ui.RenderEvents
import org.pureswift.appruntime.ui.RenderSurface

/**
 * The host's natives in `libapp.so` (Swift's `AndroidHostApp`,
 * Documentation/Plan.md §5). Main thread only.
 */
object NativeHost {

    /**
     * Starts the app from its `Info.plist` bytes, with `surface` for its
     * renderer: an empty string, or why it couldn't. A recreated Activity
     * calls it again; the app keeps running. `background`: there's no
     * window, and the app starts in the background.
     */
    external fun start(info: ByteArray, languages: Array<String>, surface: RenderSurface?, background: Boolean): String

    /** A UI event on `node`; the guest's update arrives before this returns. */
    external fun event(node: Long, kind: Int, payload: ByteArray)

    /** Rows in the lazy container `list`. */
    external fun rowCount(list: Long): Int

    /** Row `index` of `list`, as an encoded tree; empty if there's none. */
    external fun row(list: Long, index: Int): ByteArray

    /** The app's state: 0 active, 1 inactive, 2 background (`ApplicationState`). */
    external fun setState(state: Int)

    /** A URL to open; whether the app handled it. */
    external fun open(url: String): Boolean

    /** The system is low on memory. */
    external fun memoryWarning()

    /** The user's languages, as BCP 47 tags. */
    external fun setLanguages(languages: Array<String>)

    /** The player's events, through these natives. */
    val events = object : RenderEvents {
        override fun event(node: Long, kind: Int, payload: ByteArray) = NativeHost.event(node, kind, payload)
        override fun row(list: Long, index: Int): ByteArray = NativeHost.row(list, index)
    }
}
