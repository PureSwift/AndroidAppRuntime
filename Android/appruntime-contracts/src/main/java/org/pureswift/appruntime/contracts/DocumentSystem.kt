package org.pureswift.appruntime.contracts

import android.app.Activity
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.content.UriPermission
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import android.webkit.MimeTypeMap
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import java.io.FileInputStream
import java.io.FileNotFoundException
import java.io.IOException
import java.util.UUID

/**
 * The Storage Access Framework for Swift's `AndroidDocuments` and its
 * documents in `AndroidFiles` (Documentation/Plan.md §6.8).
 *
 * The pickers are shown from the Activity, which hands their results to
 * [deliver]; those reach Swift through [DocumentNatives]. Pickers and
 * bookmarks are main thread only.
 *
 * The content calls (`info`, `children`, `read`, `write`, `create`,
 * `delete`) block, and run on Swift's files queue. Each returns its value,
 * or an empty one, and leaves a `FileError` raw value for [error] on the
 * same thread: 0 when it succeeded.
 */
class DocumentSystem {

    private val context: Context get() = HostContext.application

    private val resolver: ContentResolver get() = context.contentResolver

    // MARK: Pickers

    /**
     * `ACTION_OPEN_DOCUMENT`. `types` are MIME types, MIME groups and
     * extensions; an extension Android has no MIME type for shows every
     * file. False when there's no Activity to show it from.
     */
    fun pick(id: Int, types: Array<String>, multiple: Boolean, write: Boolean): Boolean {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, multiple)
            .addFlags(grantFlags(write) or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        val mimeTypes = mimeTypes(types)
        when {
            mimeTypes == null || mimeTypes.isEmpty() -> intent.type = "*/*"
            mimeTypes.size == 1 -> intent.type = mimeTypes[0]
            else -> {
                intent.type = "*/*"
                intent.putExtra(Intent.EXTRA_MIME_TYPES, mimeTypes)
            }
        }
        return start(intent, id)
    }

    /**
     * The system's photo picker, `MediaStore.ACTION_PICK_IMAGES`, where
     * Android or Google Play services has it, and `ACTION_OPEN_DOCUMENT`
     * for images and videos where neither does. `kinds`: bits, 1 images,
     * 2 videos; none means both. Its URIs are read-only and last until the
     * app stops, and it asks for no permission.
     */
    fun pickPhotos(id: Int, kinds: Int, multiple: Boolean): Boolean {
        val activity = HostContext.activity ?: return false
        val images = kinds and 1 != 0
        val videos = kinds and 2 != 0
        val type = when {
            images && !videos -> ActivityResultContracts.PickVisualMedia.ImageOnly
            videos && !images -> ActivityResultContracts.PickVisualMedia.VideoOnly
            else -> ActivityResultContracts.PickVisualMedia.ImageAndVideo
        }
        val request = PickVisualMediaRequest.Builder().setMediaType(type).build()
        val intent = if (multiple) {
            ActivityResultContracts.PickMultipleVisualMedia().createIntent(activity, request)
        } else {
            ActivityResultContracts.PickVisualMedia().createIntent(activity, request)
        }
        return start(intent, id)
    }

    /** `ACTION_OPEN_DOCUMENT_TREE`. */
    fun pickFolder(id: Int, write: Boolean): Boolean {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
            .addFlags(grantFlags(write) or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        return start(intent, id)
    }

    /** `ACTION_CREATE_DOCUMENT`, suggesting `name`. Swift writes the file. */
    fun export(id: Int, name: String): Boolean {
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType(mimeType(name))
            .putExtra(Intent.EXTRA_TITLE, name)
        return start(intent, id)
    }

    private fun start(intent: Intent, id: Int): Boolean {
        val activity = HostContext.activity ?: return false
        return try {
            @Suppress("DEPRECATION")
            activity.startActivityForResult(intent, REQUEST + id)
            true
        } catch (error: android.content.ActivityNotFoundException) {
            false
        }
    }

    // MARK: Bookmarks

    /**
     * Keeps the access to `uri` past this run, and gives the key it's kept
     * under: empty when the provider can't keep it (`unsupported`), and
     * `"-"` when Android keeps no more (`limitReached`).
     */
    fun remember(uri: String, isDirectory: Boolean, write: Boolean): String {
        val parsed = Uri.parse(uri)
        val held = resolver.persistedUriPermissions.any { it.uri == parsed }
        if (!held && resolver.persistedUriPermissions.size >= PERSISTED_LIMIT) {
            return "-"
        }
        try {
            resolver.takePersistableUriPermission(parsed, grantFlags(write))
        } catch (error: SecurityException) {
            if (!write) return ""
            // Given for reading only, after all.
            try {
                resolver.takePersistableUriPermission(parsed, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            } catch (error: SecurityException) {
                return ""
            }
        }
        val key = UUID.randomUUID().toString()
        bookmarks.edit().putString(key, "${if (isDirectory) 1 else 0}${if (write) 1 else 0}$uri").apply()
        return key
    }

    /**
     * What `key` was kept for: the URI, whether it's a folder (`"1"`), and
     * whether it may be written (`"1"`). Empty when the key isn't one
     * (`notFound`), and only the URI when the access was taken back
     * (`notPermitted`).
     */
    fun recall(key: String): Array<String> {
        val value = bookmarks.getString(key, null) ?: return emptyArray()
        if (value.length < 3) return emptyArray()
        val uri = value.substring(2)
        val parsed = Uri.parse(uri)
        val permission = resolver.persistedUriPermissions.firstOrNull { it.uri == parsed }
            ?: return arrayOf(uri)
        val write = value[1] == '1' && permission.isWritePermission
        return arrayOf(uri, value.substring(0, 1), if (write) "1" else "0")
    }

    /** Lets a bookmark go; its access too, when no other bookmark has it. */
    fun forget(key: String) {
        val value = bookmarks.getString(key, null) ?: return
        bookmarks.edit().remove(key).apply()
        val uri = value.substring(2)
        val shared = bookmarks.all.any { (other, kept) -> other != key && (kept as? String)?.substring(2) == uri }
        if (!shared) {
            val parsed = Uri.parse(uri)
            resolver.persistedUriPermissions.firstOrNull { it.uri == parsed }?.let { release(it) }
        }
    }

    private fun release(permission: UriPermission) {
        var flags = 0
        if (permission.isReadPermission) flags = flags or Intent.FLAG_GRANT_READ_URI_PERMISSION
        if (permission.isWritePermission) flags = flags or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        try {
            resolver.releasePersistableUriPermission(permission.uri, flags)
        } catch (error: SecurityException) {
        }
    }

    private val bookmarks get() = context.getSharedPreferences(BOOKMARKS, Context.MODE_PRIVATE)

    // MARK: Content

    /** The `FileError` the last content call on this thread left: 0 for none. */
    fun error(): Int = lastError.get() ?: 0

    /**
     * What a document is: its name, MIME type, `"1"` for a folder, size,
     * modification time in milliseconds (0 if unknown), and `"1"` when it
     * can be written: a file's contents, or a folder's children.
     *
     * A URI that isn't a provider's document, as another app's
     * `FileProvider` or MediaStore gives with open-with, may have only a
     * name and a size, and counts as writable: the intent's grant decides.
     */
    fun info(uri: String): Array<String> = content {
        val parsed = Uri.parse(uri)
        // MediaStore refuses columns it doesn't have; asked for none, a
        // provider gives what it has.
        val query = try {
            resolver.query(parsed, INFO, null, null, null)
        } catch (error: IllegalArgumentException) {
            resolver.query(parsed, null, null, null, null)
        }
        query?.use { cursor ->
            if (!cursor.moveToFirst()) throw FileFailure(NOT_FOUND)
            describe(cursor, parsed)
        } ?: throw FileFailure(NOT_FOUND)
    } ?: emptyArray()

    /**
     * A folder's children, as `uri, name, "1" for a folder` three at a
     * time. `uri` is a document of a tree the user picked.
     */
    fun children(uri: String): Array<String> = content {
        val document = Uri.parse(uri)
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(document, DocumentsContract.getDocumentId(document))
        resolver.query(children, CHILDREN, null, null, null)?.use { cursor ->
            val found = ArrayList<String>(cursor.count * 3)
            while (cursor.moveToNext()) {
                val id = cursor.getString(0)
                found += DocumentsContract.buildDocumentUriUsingTree(document, id).toString()
                found += cursor.getString(1) ?: id
                found += if (cursor.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR) "1" else "0"
            }
            found.toTypedArray()
        } ?: throw FileFailure(NOT_FOUND)
    } ?: emptyArray()

    /**
     * Up to `length` bytes from `offset`; to the end when `length` is −1.
     * A provider without a seekable descriptor is read through from the
     * start.
     */
    fun read(uri: String, offset: Long, length: Long): ByteArray = content {
        val descriptor = resolver.openFileDescriptor(Uri.parse(uri), "r") ?: throw FileFailure(NOT_FOUND)
        descriptor.use {
            FileInputStream(it.fileDescriptor).use { input ->
                val channel = input.channel
                val seekable = try {
                    channel.position(offset)
                    true
                } catch (error: IOException) {
                    false
                }
                if (!seekable) {
                    var skipped = 0L
                    while (skipped < offset) {
                        val step = input.skip(offset - skipped)
                        if (step <= 0) {
                            if (input.read() < 0) return@use ByteArray(0)
                            skipped += 1
                        } else {
                            skipped += step
                        }
                    }
                }
                if (length < 0) {
                    input.readBytes()
                } else {
                    val bytes = ByteArray(length.toInt())
                    var filled = 0
                    while (filled < bytes.size) {
                        val count = input.read(bytes, filled, bytes.size - filled)
                        if (count < 0) break
                        filled += count
                    }
                    if (filled == bytes.size) bytes else bytes.copyOf(filled)
                }
            }
        }
    } ?: ByteArray(0)

    /**
     * Replaces the file's contents, or adds to them. A provider offers
     * only truncate-and-write, so a replacement isn't atomic.
     */
    fun write(uri: String, bytes: ByteArray, append: Boolean): Boolean = content {
        val stream = resolver.openOutputStream(Uri.parse(uri), if (append) "wa" else "wt")
            ?: throw FileFailure(NOT_FOUND)
        stream.use { it.write(bytes) }
        true
    } ?: false

    /**
     * Makes a file or a folder named `name` in the folder `parent`, and
     * gives its URI. A file's MIME type comes from its extension, so the
     * provider keeps the name as it is.
     */
    fun create(parent: String, name: String, isDirectory: Boolean): String = content {
        val type = if (isDirectory) DocumentsContract.Document.MIME_TYPE_DIR else mimeType(name)
        DocumentsContract.createDocument(resolver, Uri.parse(parent), type, name)?.toString()
            ?: throw FileFailure(READ_ONLY)
    } ?: ""

    /** Removes a file, or a folder and all in it. */
    fun delete(uri: String): Boolean = content {
        if (!DocumentsContract.deleteDocument(resolver, Uri.parse(uri))) throw FileFailure(UNKNOWN)
        true
    } ?: false

    /** Runs a content call, keeping its error for [error]. */
    private inline fun <T> content(body: () -> T): T? {
        lastError.set(0)
        return try {
            body()
        } catch (failure: FileFailure) {
            lastError.set(failure.code)
            null
        } catch (error: FileNotFoundException) {
            lastError.set(NOT_FOUND)
            null
        } catch (error: SecurityException) {
            lastError.set(NOT_PERMITTED)
            null
        } catch (error: UnsupportedOperationException) {
            lastError.set(READ_ONLY)
            null
        } catch (error: IllegalArgumentException) {
            // A URI the provider doesn't know: it went away.
            lastError.set(NOT_FOUND)
            null
        } catch (error: IOException) {
            lastError.set(if (error.message?.contains("ENOSPC") == true) OUT_OF_SPACE else UNAVAILABLE)
            null
        }
    }

    private fun describe(cursor: Cursor, uri: Uri): Array<String> {
        fun column(name: String): Int = cursor.getColumnIndex(name).takeIf { it >= 0 && !cursor.isNull(it) } ?: -1
        val nameColumn = column(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
        val mimeColumn = column(DocumentsContract.Document.COLUMN_MIME_TYPE)
        val sizeColumn = column(DocumentsContract.Document.COLUMN_SIZE)
        val modifiedColumn = column(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
        val flagsColumn = column(DocumentsContract.Document.COLUMN_FLAGS)
        val mime = (if (mimeColumn >= 0) cursor.getString(mimeColumn) else resolver.getType(uri)) ?: ""
        val isDirectory = mime == DocumentsContract.Document.MIME_TYPE_DIR
        val writable = when {
            flagsColumn < 0 -> true
            isDirectory -> cursor.getInt(flagsColumn) and DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE != 0
            else -> cursor.getInt(flagsColumn) and DocumentsContract.Document.FLAG_SUPPORTS_WRITE != 0
        }
        return arrayOf(
            (if (nameColumn >= 0) cursor.getString(nameColumn) else uri.lastPathSegment) ?: "",
            if (isDirectory) "" else mime,
            if (isDirectory) "1" else "0",
            if (isDirectory || sizeColumn < 0) "0" else cursor.getLong(sizeColumn).toString(),
            if (modifiedColumn < 0) "0" else cursor.getLong(modifiedColumn).toString(),
            if (writable) "1" else "0",
        )
    }

    private class FileFailure(val code: Int) : Exception()

    companion object {

        /** Request codes from here up are the pickers'. */
        private const val REQUEST = 0x4400

        /** `shared_prefs/org.pureswift.appruntime.documents.xml`. */
        const val BOOKMARKS = "org.pureswift.appruntime.documents"

        // FileError raw values.
        private const val UNKNOWN = 0
        private const val NOT_FOUND = 2
        private const val READ_ONLY = 7
        private const val OUT_OF_SPACE = 8
        private const val NOT_PERMITTED = 10
        private const val UNAVAILABLE = 11

        /** How many persisted grants Android keeps for an app. */
        private val PERSISTED_LIMIT = if (Build.VERSION.SDK_INT >= 30) 512 else 128

        /** Asked of any URI; a provider leaves out the columns it doesn't have. */
        private val INFO = arrayOf(
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
            DocumentsContract.Document.COLUMN_FLAGS,
        )

        private val CHILDREN = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
        )

        private val lastError = ThreadLocal<Int>()

        private fun grantFlags(write: Boolean): Int =
            Intent.FLAG_GRANT_READ_URI_PERMISSION or (if (write) Intent.FLAG_GRANT_WRITE_URI_PERMISSION else 0)

        /** The MIME type for a file's name, by its extension. */
        fun mimeType(name: String): String {
            val dot = name.lastIndexOf('.')
            if (dot < 0) return "application/octet-stream"
            val extension = name.substring(dot + 1).lowercase()
            return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension) ?: "application/octet-stream"
        }

        /** The picker's MIME types; null when one can't be said, so any file shows. */
        fun mimeTypes(types: Array<String>): Array<String>? {
            val mimeTypes = LinkedHashSet<String>()
            for (type in types) {
                if (type.startsWith(".")) {
                    val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(type.substring(1).lowercase())
                        ?: return null
                    mimeTypes += mime
                } else {
                    mimeTypes += type
                }
            }
            return mimeTypes.toTypedArray()
        }

        /**
         * The Activity's `onActivityResult`: true when it was a picker's.
         * A folder is the document at the top of the tree that was picked.
         */
        fun deliver(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
            if (requestCode < REQUEST || requestCode >= REQUEST + 0x100) return false
            val id = requestCode - REQUEST
            val uris = ArrayList<String>()
            if (resultCode == Activity.RESULT_OK && data != null) {
                val clips = data.clipData
                if (clips != null) {
                    for (index in 0 until clips.itemCount) {
                        clips.getItemAt(index).uri?.let { uris += it.toString() }
                    }
                } else {
                    data.data?.let { uri ->
                        uris += if (DocumentsContract.isTreeUri(uri) && !DocumentsContract.isDocumentUri(HostContext.application, uri)) {
                            DocumentsContract.buildDocumentUriUsingTree(uri, DocumentsContract.getTreeDocumentId(uri)).toString()
                        } else {
                            uri.toString()
                        }
                    }
                }
            }
            DocumentNatives.picked(id, uris.toTypedArray())
            return true
        }

        /**
         * An `ACTION_VIEW` or `ACTION_EDIT` intent for a file: true when it
         * was one, and went to the guest's documents.
         */
        fun open(intent: Intent): Boolean {
            if (intent.action != Intent.ACTION_VIEW && intent.action != Intent.ACTION_EDIT) return false
            val uri = intent.data ?: return false
            if (uri.scheme != ContentResolver.SCHEME_CONTENT) return false
            val write = intent.action == Intent.ACTION_EDIT &&
                intent.flags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION != 0
            DocumentNatives.opened(arrayOf(uri.toString()), write)
            return true
        }
    }
}

/** What [DocumentSystem]'s pickers and intents give, for Swift. Main thread. */
object DocumentNatives {

    /** A picker's URIs; none when the user cancelled. */
    external fun picked(id: Int, uris: Array<String>)

    /** Files the app was opened with. */
    external fun opened(uris: Array<String>, write: Boolean)
}
