package org.pureswift.appruntime.contracts

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.PersistableBundle
import androidx.core.content.FileProvider
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException

/**
 * Android's clipboard for Swift's `AndroidClipboardPlatform`
 * (Documentation/Plan.md §6.11). Swift checks what's copied and pasted;
 * this class only talks to `ClipboardManager`. Main thread only.
 *
 * A read works while the app has focus, and from Android 12 the system
 * tells the user it happened. A copied image is a file in the app's cache,
 * shared through [ClipboardFileProvider].
 */
class ClipboardSystem {

    private val context: Context get() = HostContext.application

    private val manager: ClipboardManager
        get() = context.getSystemService(ClipboardManager::class.java)

    /** The type the last [readImage] gave: `image/png` or `image/jpeg`. */
    private var imageType = ""

    /** The `PasteboardError` the last read left; 0 for none. */
    private var readError = 0

    /**
     * What a read might give, from the clip's description alone, which
     * shows the user nothing: bits, 1 text, 2 a URL, 4 an image.
     */
    fun available(): Int {
        val description = manager.primaryClipDescription ?: return 0
        var kinds = 0
        if (description.hasMimeType("text/*")) kinds = kinds or TEXT
        // A URL is text too: readText gives it.
        if (description.hasMimeType(ClipDescription.MIMETYPE_TEXT_URILIST)) kinds = kinds or TEXT or URL
        if (description.hasMimeType("image/*")) kinds = kinds or IMAGE
        return kinds
    }

    fun clear() {
        manager.clearPrimaryClip()
    }

    /** Text, and with `url` not empty, the URL too. */
    fun writeText(text: String, url: String, sensitive: Boolean) {
        val clip = if (url.isEmpty()) {
            ClipData.newPlainText("", text)
        } else {
            ClipData(
                ClipDescription("", arrayOf(ClipDescription.MIMETYPE_TEXT_PLAIN, ClipDescription.MIMETYPE_TEXT_URILIST)),
                ClipData.Item(text, null, Uri.parse(url)),
            )
        }
        set(clip, sensitive)
    }

    /**
     * An image, PNG or JPEG: a file of the app's cache, which other apps
     * read through the provider. A `PasteboardError`, or 0.
     */
    fun writeImage(bytes: ByteArray, extension: String, sensitive: Boolean): Int {
        val directory = File(context.cacheDir, "appruntime-clipboard")
        val file = File(directory, "image-${System.currentTimeMillis()}.$extension")
        return try {
            directory.mkdirs()
            // Only the image on the clipboard is kept.
            directory.listFiles()?.forEach { it.delete() }
            file.writeBytes(bytes)
            val uri = FileProvider.getUriForFile(context, context.packageName + ".appruntime.clipboard", file)
            set(ClipData.newUri(context.contentResolver, "", uri), sensitive)
            0
        } catch (error: IOException) {
            UNKNOWN
        } catch (error: IllegalArgumentException) {
            UNKNOWN
        }
    }

    private fun set(clip: ClipData, sensitive: Boolean) {
        if (sensitive) {
            // ClipDescription.EXTRA_IS_SENSITIVE, which Android 13 reads.
            clip.description.extras = PersistableBundle().apply { putBoolean(EXTRA_IS_SENSITIVE, true) }
        }
        manager.setPrimaryClip(clip)
    }

    /** The `PasteboardError` the last read left; 0 for none. */
    fun error(): Int = readError

    /** The clip's text, or a URL's where it has no text; empty for none. */
    fun readText(): Array<String> = read { clip ->
        for (index in 0 until clip.itemCount) {
            val item = clip.getItemAt(index)
            item.text?.let { return@read arrayOf(it.toString()) }
            item.uri?.takeIf(::isWeb)?.let { return@read arrayOf(it.toString()) }
        }
        emptyArray()
    } ?: emptyArray()

    /** The clip's URL, not parsed from text; empty for none. */
    fun readURL(): Array<String> = read { clip ->
        for (index in 0 until clip.itemCount) {
            clip.getItemAt(index).uri?.takeIf(::isWeb)?.let { return@read arrayOf(it.toString()) }
        }
        emptyArray()
    } ?: emptyArray()

    /**
     * The clip's image, PNG or JPEG as it is, and anything else Android can
     * decode as PNG; empty for none. Its type is [imageType]'s.
     */
    fun readImage(): ByteArray = read { clip ->
        imageType = ""
        for (index in 0 until clip.itemCount) {
            val uri = clip.getItemAt(index).uri ?: continue
            val type = context.contentResolver.getType(uri) ?: continue
            if (!type.startsWith("image/")) continue
            val bytes = context.contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: continue
            return@read when {
                isPNG(bytes) -> bytes.also { imageType = "image/png" }
                isJPEG(bytes) -> bytes.also { imageType = "image/jpeg" }
                else -> {
                    val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: run {
                        readError = INVALID_DATA
                        return@read ByteArray(0)
                    }
                    val png = ByteArrayOutputStream()
                    bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, png)
                    imageType = "image/png"
                    png.toByteArray()
                }
            }
        }
        ByteArray(0)
    } ?: ByteArray(0)

    /** The type the last [readImage] gave. */
    fun imageType(): String = imageType

    /** Runs a read of the clip, keeping its error for [error]. */
    private inline fun <T> read(body: (ClipData) -> T): T? {
        readError = 0
        return try {
            val clip = manager.primaryClip ?: return null
            body(clip)
        } catch (error: SecurityException) {
            readError = NOT_ALLOWED
            null
        } catch (error: IOException) {
            readError = UNKNOWN
            null
        }
    }

    private fun isWeb(uri: Uri): Boolean = uri.scheme == "http" || uri.scheme == "https"

    private fun isPNG(bytes: ByteArray): Boolean =
        bytes.size >= 8 && bytes[0] == 0x89.toByte() && bytes[1] == 'P'.code.toByte() && bytes[2] == 'N'.code.toByte() && bytes[3] == 'G'.code.toByte()

    private fun isJPEG(bytes: ByteArray): Boolean =
        bytes.size >= 3 && bytes[0] == 0xFF.toByte() && bytes[1] == 0xD8.toByte() && bytes[2] == 0xFF.toByte()

    private companion object {
        const val TEXT = 1
        const val URL = 2
        const val IMAGE = 4

        const val EXTRA_IS_SENSITIVE = "android.content.extra.IS_SENSITIVE"

        // PasteboardError raw values.
        const val UNKNOWN = 0
        const val NOT_ALLOWED = 2
        const val INVALID_DATA = 4
    }
}

/** Shares the image the app copied: a provider of its own, so it can't clash with the app's. */
class ClipboardFileProvider : FileProvider()
