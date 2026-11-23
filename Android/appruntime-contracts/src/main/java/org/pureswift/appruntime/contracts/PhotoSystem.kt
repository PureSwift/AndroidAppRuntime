package org.pureswift.appruntime.contracts

import android.app.Activity
import android.content.ContentResolver
import android.content.ContentUris
import android.content.ContentValues
import android.database.ContentObserver
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Size
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.util.UUID

/**
 * The `Photos` contract's Android side (Documentation/Plan.md §6.18): the
 * user's photos and videos as `MediaStore` keeps them. Swift's
 * `AndroidPhotoStore` asks for them off the main thread, and reads each
 * call's error with [error] on the same thread.
 *
 * An asset's identifier is its kind and its row: `image/42`, `video/7`.
 * It lasts as long as the row. An album is a bucket: the folder a photo
 * is in. With the access Android 14 gives to some photos, the provider
 * answers with those alone.
 */
class PhotoSystem {

    private val context get() = HostContext.application

    private val resolver: ContentResolver get() = context.contentResolver

    /** The last call's error on this thread: a `PhotoLibraryError`, -1 for `unknown`, 0 for none. */
    fun error(): Int = lastError.get() ?: 0

    // MARK: Reading, off the main thread

    /** The identifiers of `kind` (0 both, 1 image, 2 video), in a bucket or all: newest first. */
    fun identifiers(kind: Int, album: String): Array<String> = call {
        val found = rows(kind, album)
        if (found.isEmpty() && album.isNotEmpty() && rows(0, album).isEmpty()) throw Failure(NOT_FOUND)
        found.toTypedArray()
    } ?: emptyArray()

    /** The rows of `kind` in `album`, newest first, as identifiers. */
    private fun rows(kind: Int, album: String): List<String> {
        val selection = StringBuilder(mediaTypes(kind))
        val arguments = ArrayList<String>()
        if (album.isNotEmpty()) {
            selection.append(" AND ${MediaStore.MediaColumns.BUCKET_ID} = ?")
            arguments += album
        }
        val rows = ArrayList<Triple<Long, Long, String>>()
        resolver.query(FILES, arrayOf(ID, TYPE, TAKEN, ADDED), selection.toString(), arguments.toTypedArray(), null)?.use { cursor ->
            while (cursor.moveToNext()) {
                val id = cursor.getLong(0)
                val date = if (cursor.isNull(2)) cursor.getLong(3) * 1000 else cursor.getLong(2)
                rows += Triple(date, id, identifier(cursor.getInt(1), id))
            }
        }
        rows.sortWith(compareByDescending<Triple<Long, Long, String>> { it.first }.thenByDescending { it.second })
        return rows.map { it.third }
    }

    /** Seven strings for each asset that's still there, in any order. */
    fun assets(identifiers: Array<String>): Array<String> = call {
        val fields = ArrayList<String>()
        for ((type, ids) in identifiers.mapNotNull(::parse).groupBy({ it.first }, { it.second })) {
            for (chunk in ids.chunked(500)) {
                val projection = arrayListOf(ID, TAKEN, ADDED, WIDTH, HEIGHT, ORIENTATION, DURATION)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) projection += FAVORITE
                val selection = "$ID IN (${chunk.joinToString(",")})"
                resolver.query(collection(type), projection.toTypedArray(), selection, null, null)?.use { cursor ->
                    while (cursor.moveToNext()) {
                        val date = if (cursor.isNull(1)) cursor.getLong(2) * 1000 else cursor.getLong(1)
                        var width = cursor.getInt(3)
                        var height = cursor.getInt(4)
                        // The upright picture's size.
                        if (cursor.getInt(5) % 180 == 90) width = height.also { height = width }
                        val duration = if (type == VIDEO) cursor.getLong(6) else 0
                        val favorite = projection.size > 7 && cursor.getInt(7) == 1
                        fields += listOf(
                            identifier(type, cursor.getLong(0)), if (type == VIDEO) "2" else "1", date.toString(),
                            width.toString(), height.toString(), duration.toString(), if (favorite) "1" else "0",
                        )
                    }
                }
            }
        }
        fields.toTypedArray()
    } ?: emptyArray()

    /** Four strings for each album: its bucket, its name, how many, and 1, an album the user's photos make. */
    fun albums(): Array<String> = call {
        val counts = LinkedHashMap<String, Pair<String, Int>>()
        val projection = arrayOf(MediaStore.MediaColumns.BUCKET_ID, MediaStore.MediaColumns.BUCKET_DISPLAY_NAME)
        resolver.query(FILES, projection, mediaTypes(0), null, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                val bucket = cursor.getString(0) ?: continue
                val name = cursor.getString(1) ?: ""
                counts[bucket] = name to ((counts[bucket]?.second ?: 0) + 1)
            }
        }
        counts.entries.sortedBy { it.value.first.lowercase() }
            .flatMap { (bucket, value) -> listOf(bucket, value.first, value.second.toString(), "1") }
            .toTypedArray()
    } ?: emptyArray()

    // MARK: Adding, off the main thread

    /**
     * Copies the file at `path` into the library, as `kind` (1 image, 2
     * video), in the shared Pictures or Movies folder, under the app's
     * name; its seven strings.
     */
    fun add(path: String, kind: Int): Array<String> = call {
        val file = File(path)
        val type = if (kind == 2) VIDEO else IMAGE
        val mime = mimeType(file) ?: throw Failure(INVALID_DATA)
        val folder = if (type == VIDEO) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_PICTURES
        val label = context.applicationInfo.loadLabel(context.packageManager).toString().replace('/', '_')
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, file.name)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
        }
        val uri: Uri
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            values.put(MediaStore.MediaColumns.RELATIVE_PATH, "$folder/$label")
            values.put(MediaStore.MediaColumns.IS_PENDING, 1)
            uri = resolver.insert(collection(type), values) ?: throw Failure(UNKNOWN)
            try {
                resolver.openOutputStream(uri)?.use { output -> file.inputStream().use { it.copyTo(output) } }
                    ?: throw Failure(UNKNOWN)
            } catch (error: IOException) {
                resolver.delete(uri, null, null)
                throw Failure(UNKNOWN)
            }
            resolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
        } else {
            // Android 9: the file in the shared folder, with WRITE_EXTERNAL_STORAGE.
            @Suppress("DEPRECATION")
            val directory = File(Environment.getExternalStoragePublicDirectory(folder), label).apply { mkdirs() }
            var target = File(directory, file.name)
            if (target.exists()) target = File(directory, "${UUID.randomUUID()}-${file.name}")
            file.copyTo(target)
            @Suppress("DEPRECATION")
            values.put(MediaStore.MediaColumns.DATA, target.absolutePath)
            uri = resolver.insert(collection(type), values) ?: throw Failure(UNKNOWN)
        }
        val added = assets(arrayOf(identifier(type, ContentUris.parseId(uri))))
        if (added.isEmpty()) throw Failure(UNKNOWN)
        added
    } ?: emptyArray()

    // MARK: Originals, off the main thread

    /** The original, copied to the app's cache: its path, its MIME type and its name. */
    fun original(identifier: String): Array<String> = call {
        val (type, id) = parse(identifier) ?: throw Failure(NOT_FOUND)
        val uri = ContentUris.withAppendedId(collection(type), id)
        var name = ""
        var mime = ""
        resolver.query(uri, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME, MediaStore.MediaColumns.MIME_TYPE), null, null, null)?.use { cursor ->
            if (!cursor.moveToFirst()) throw Failure(NOT_FOUND)
            name = cursor.getString(0) ?: ""
            mime = cursor.getString(1) ?: ""
        } ?: throw Failure(NOT_FOUND)
        val directory = File(context.cacheDir, "photo-originals/${UUID.randomUUID()}").apply { mkdirs() }
        val copy = File(directory, name.ifEmpty { "original" }.replace('/', '_'))
        try {
            resolver.openInputStream(uri)?.use { input -> copy.outputStream().use { input.copyTo(it) } } ?: throw Failure(NOT_FOUND)
        } catch (error: FileNotFoundException) {
            directory.deleteRecursively()
            throw Failure(NOT_FOUND)
        } catch (error: IOException) {
            directory.deleteRecursively()
            throw Failure(UNAVAILABLE)
        }
        arrayOf(copy.absolutePath, mime, name)
    } ?: emptyArray()

    /** Removes an original's copy. */
    fun release(path: String) {
        File(path).parentFile?.takeIf { it.parentFile?.name == "photo-originals" }?.deleteRecursively()
    }

    // MARK: Deleting, on the main thread

    /**
     * Deletes the assets, answering [PhotoNatives.deleted] with `request`.
     * The app's own are deleted at once. The others go through the
     * system's question, from Android 11, which deletes all or none.
     */
    fun delete(identifiers: Array<String>, request: Int) {
        val uris = identifiers.mapNotNull(::parse).map { (type, id) -> ContentUris.withAppendedId(collection(type), id) }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && !uris.all(::isOwn)) {
                val activity = HostContext.activity ?: return PhotoNatives.deleted(request, NOT_AUTHORIZED)
                val slot = nextSlot++ and 0xFF
                pending[slot] = request
                val sender = MediaStore.createDeleteRequest(resolver, uris).intentSender
                activity.startIntentSenderForResult(sender, REQUEST + slot, null, 0, 0, 0)
                return
            }
            for (uri in uris) resolver.delete(uri, null, null)
            PhotoNatives.deleted(request, 0)
        } catch (error: SecurityException) {
            PhotoNatives.deleted(request, NOT_AUTHORIZED)
        } catch (error: Exception) {
            PhotoNatives.deleted(request, UNKNOWN)
        }
    }

    private fun isOwn(uri: Uri): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
        resolver.query(uri, arrayOf(MediaStore.MediaColumns.OWNER_PACKAGE_NAME), null, null, null)?.use { cursor ->
            return cursor.moveToFirst() && cursor.getString(0) == context.packageName
        }
        return false
    }

    // MARK: Changes

    /** Starts telling [PhotoNatives.changed] when the library changes. */
    fun observe() {
        if (observer != null) return
        val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) {
                PhotoNatives.changed()
            }
        }
        try {
            // The photos and videos, not every file in shared storage, which
            // changes whenever any app writes there.
            resolver.registerContentObserver(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, true, observer)
            resolver.registerContentObserver(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, true, observer)
            PhotoSystem.observer = observer
        } catch (error: SecurityException) {
        }
    }

    // MARK: Errors

    private class Failure(val code: Int) : Exception()

    /** Runs a call, keeping its error for [error]. */
    private inline fun <T> call(body: () -> T): T? {
        lastError.set(0)
        return try {
            body()
        } catch (failure: Failure) {
            lastError.set(failure.code)
            null
        } catch (error: SecurityException) {
            lastError.set(NOT_AUTHORIZED)
            null
        } catch (error: IllegalArgumentException) {
            lastError.set(UNKNOWN)
            null
        } catch (error: IllegalStateException) {
            lastError.set(UNKNOWN)
            null
        } catch (error: IOException) {
            lastError.set(UNKNOWN)
            null
        }
    }

    companion object {
        // PhotoLibraryError raw values; `unknown` as -1, since 0 is no error.
        private const val UNKNOWN = -1
        private const val NOT_AUTHORIZED = 2
        private const val UNAVAILABLE = 3
        private const val NOT_FOUND = 4
        private const val INVALID_DATA = 5
        private const val CANCELLED_BY_USER = 6

        private const val IMAGE = MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE
        private const val VIDEO = MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO

        private const val ID = MediaStore.MediaColumns._ID
        private const val TYPE = MediaStore.Files.FileColumns.MEDIA_TYPE
        private const val TAKEN = "datetaken"
        private const val ADDED = MediaStore.MediaColumns.DATE_ADDED
        private const val WIDTH = MediaStore.MediaColumns.WIDTH
        private const val HEIGHT = MediaStore.MediaColumns.HEIGHT
        private const val ORIENTATION = "orientation"
        private const val DURATION = "duration"
        private const val FAVORITE = "is_favorite"

        private val FILES: Uri = MediaStore.Files.getContentUri("external")

        private const val REQUEST = 0x4500

        private val lastError = ThreadLocal<Int>()

        private var observer: ContentObserver? = null

        /** Deletions waiting for the system's question, by request slot. */
        private val pending = HashMap<Int, Int>()

        private var nextSlot = 0

        private fun mediaTypes(kind: Int): String = when (kind) {
            1 -> "$TYPE = $IMAGE"
            2 -> "$TYPE = $VIDEO"
            else -> "$TYPE IN ($IMAGE, $VIDEO)"
        }

        private fun collection(type: Int): Uri =
            if (type == VIDEO) MediaStore.Video.Media.EXTERNAL_CONTENT_URI else MediaStore.Images.Media.EXTERNAL_CONTENT_URI

        private fun identifier(type: Int, id: Long) = (if (type == VIDEO) "video/" else "image/") + id

        /** An identifier's media type and row. */
        private fun parse(identifier: String): Pair<Int, Long>? {
            val slash = identifier.indexOf('/')
            if (slash < 0) return null
            val id = identifier.substring(slash + 1).toLongOrNull() ?: return null
            return when (identifier.substring(0, slash)) {
                "image" -> IMAGE to id
                "video" -> VIDEO to id
                else -> null
            }
        }

        /** What a file is by its first bytes: the formats `HostPhotos` lets through. */
        private fun mimeType(file: File): String? {
            val head = ByteArray(12)
            val read = try {
                file.inputStream().use { it.read(head) }
            } catch (error: IOException) {
                return null
            }
            if (read >= 3 && head[0] == 0xFF.toByte() && head[1] == 0xD8.toByte() && head[2] == 0xFF.toByte()) return "image/jpeg"
            if (read >= 8 && head[0] == 0x89.toByte() && head[1] == 'P'.code.toByte() && head[2] == 'N'.code.toByte()) return "image/png"
            if (read >= 12 && String(head, 4, 4, Charsets.US_ASCII) == "ftyp") {
                return when (String(head, 8, 4, Charsets.US_ASCII)) {
                    "heic", "heix", "heim", "heis", "mif1", "msf1" -> "image/heic"
                    "qt  " -> "video/quicktime"
                    else -> "video/mp4"
                }
            }
            return null
        }

        /** The answer to the system's question about deleting. */
        fun deliver(requestCode: Int, resultCode: Int): Boolean {
            if (requestCode < REQUEST || requestCode >= REQUEST + 0x100) return false
            val request = pending.remove(requestCode - REQUEST) ?: return true
            PhotoNatives.deleted(request, if (resultCode == Activity.RESULT_OK) 0 else CANCELLED_BY_USER)
            return true
        }

        /**
         * A thumbnail of the asset, about `width` by `height` pixels, or
         * null when there's none or the app may not see it. Off the main
         * thread: the player's `Photo` node.
         */
        fun thumbnail(identifier: String, width: Int, height: Int): Bitmap? {
            val (type, id) = parse(identifier) ?: return null
            val resolver = HostContext.application.contentResolver
            return try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    resolver.loadThumbnail(ContentUris.withAppendedId(collection(type), id), Size(width.coerceAtLeast(1), height.coerceAtLeast(1)), null)
                } else if (type == VIDEO) {
                    @Suppress("DEPRECATION")
                    MediaStore.Video.Thumbnails.getThumbnail(resolver, id, MediaStore.Video.Thumbnails.MINI_KIND, null)
                } else {
                    @Suppress("DEPRECATION")
                    MediaStore.Images.Thumbnails.getThumbnail(resolver, id, MediaStore.Images.Thumbnails.MINI_KIND, null)
                }
            } catch (error: Exception) {
                null
            }
        }
    }
}

/** What the library reports to Swift's `PhotoHub`, on the main thread. */
object PhotoNatives {

    /** The library changed. */
    external fun changed()

    /** A deletion is over: 0, or a `PhotoLibraryError`. */
    external fun deleted(request: Int, error: Int)
}
