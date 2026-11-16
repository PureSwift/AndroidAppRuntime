package org.pureswift.appruntime.contracts

import android.content.res.AssetManager

/**
 * Where Swift's `AndroidFiles` keeps the app's files: its `filesDir` and
 * `cacheDir`, and the APK's assets, which it reads through the NDK.
 * Main thread only.
 */
class FileSystem {

    private val context get() = HostContext.application

    /** The app's `filesDir`: backed up, and kept until the app is removed. */
    fun filesDirectory(): String = context.filesDir.absolutePath

    /** The app's `cacheDir`: the system may delete what's in it. */
    fun cacheDirectory(): String = context.cacheDir.absolutePath

    /** The APK's assets, which live as long as the application. */
    fun assets(): AssetManager = context.assets
}
