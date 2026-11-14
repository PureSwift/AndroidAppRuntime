package org.pureswift.appruntime.contracts

import android.nfc.FormatException
import android.nfc.NdefMessage
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.tech.IsoDep
import android.nfc.tech.Ndef
import android.nfc.tech.NdefFormatable
import android.nfc.tech.NfcA
import android.nfc.tech.NfcF
import android.nfc.tech.NfcV
import android.nfc.tech.TagTechnology
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * The NFC contracts' Android side (Swift's `AndroidHostNFC`): reader mode
 * on the resumed Activity, and each tag's I/O on a background thread, with
 * results posted to the main thread for [NfcNatives]. Main thread only.
 */
class NfcSystem {

    private val adapter: NfcAdapter? get() = NfcAdapter.getDefaultAdapter(HostContext.application)

    private val io: ExecutorService = Executors.newSingleThreadExecutor { Thread(it, "AppRuntime NFC").apply { isDaemon = true } }

    // The main thread and the tag thread both use these.
    private val tags = ConcurrentHashMap<Long, Tag>()

    private val connections = ConcurrentHashMap<Long, TagTechnology>()

    private var lastTag = 0L

    /** `NFCAvailability`: 0 no NFC, 1 turned off, 2 available. */
    fun availability(): Int {
        val adapter = adapter ?: return 0
        return if (adapter.isEnabled) 2 else 1
    }

    /** 0, or an `NFCError` raw value: 2 no NFC, 3 off, 7 no Activity in the foreground. */
    fun begin(session: Long, flags: Int): Int {
        val adapter = adapter ?: return 2
        if (!adapter.isEnabled) return 3
        val activity = HostContext.activity ?: return 7
        val callback = NfcAdapter.ReaderCallback { tag -> HostContext.main.post { discovered(session, tag) } }
        return try {
            adapter.enableReaderMode(activity, callback, flags or NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK, null)
            0
        } catch (error: RuntimeException) {
            7
        }
    }

    fun end(session: Long) {
        val activity = HostContext.activity ?: return
        runCatching { adapter?.disableReaderMode(activity) }
    }

    private fun discovered(session: Long, tag: Tag) {
        val handle = ++lastTag
        tags[handle] = tag
        val historical = IsoDep.get(tag)?.let { it.historicalBytes ?: it.hiLayerResponse } ?: ByteArray(0)
        val maximum = when {
            IsoDep.get(tag) != null -> IsoDep.get(tag).maxTransceiveLength
            NfcA.get(tag) != null -> NfcA.get(tag).maxTransceiveLength
            NfcF.get(tag) != null -> NfcF.get(tag).maxTransceiveLength
            NfcV.get(tag) != null -> NfcV.get(tag).maxTransceiveLength
            else -> 0
        }
        NfcNatives.discovered(session, handle, tag.techList, tag.id ?: ByteArray(0), historical, maximum)
    }

    /** Connects through `technology`, a class name from the tag's tech list. */
    fun connect(tag: Long, technology: String) {
        val found = tags[tag] ?: return report(tag, CONNECT, error = IOException("the tag is gone"))
        io.execute {
            try {
                val connection: TagTechnology = when (technology) {
                    IsoDep::class.java.name -> IsoDep.get(found)
                    NfcA::class.java.name -> NfcA.get(found)
                    NfcF::class.java.name -> NfcF.get(found)
                    NfcV::class.java.name -> NfcV.get(found)
                    else -> Ndef.get(found)
                } ?: throw IOException("the tag has no $technology")
                connection.connect()
                connections[tag] = connection
                report(tag, CONNECT)
            } catch (error: Exception) {
                report(tag, CONNECT, error = error)
            }
        }
    }

    /** One `NFCOperation` on the tag's thread. */
    fun perform(operation: Int, tag: Long, data: ByteArray) {
        val found = tags[tag]
        io.execute {
            try {
                when (operation) {
                    QUERY -> {
                        val ndef = found?.let(Ndef::get)
                        when {
                            ndef != null -> report(tag, operation, status = if (ndef.isWritable) 1 else 2, capacity = ndef.maxSize)
                            found != null && NdefFormatable.get(found) != null -> report(tag, operation, status = 1, capacity = 0)
                            else -> report(tag, operation, status = 0)
                        }
                    }
                    READ -> {
                        val ndef = ndef(tag, found)
                        report(tag, operation, bytes = ndef.ndefMessage?.toByteArray() ?: ByteArray(0))
                    }
                    WRITE -> {
                        val message = NdefMessage(data)
                        val ndef = found?.let(Ndef::get)
                        if (ndef != null) {
                            if (!ndef.isWritable) throw StatusException("ReadOnly")
                            if (data.size > ndef.maxSize) throw StatusException("Capacity")
                            ensureConnected(ndef)
                            ndef.writeNdefMessage(message)
                        } else {
                            val formatable = found?.let(NdefFormatable::get) ?: throw StatusException("NotNDEF")
                            formatable.connect()
                            formatable.use { it.format(message) }
                        }
                        report(tag, operation)
                    }
                    LOCK -> {
                        val ndef = ndef(tag, found)
                        if (!ndef.canMakeReadOnly() || !ndef.makeReadOnly()) throw StatusException("ReadOnly")
                        report(tag, operation)
                    }
                    TRANSCEIVE -> {
                        val response = when (val connection = connections[tag]) {
                            is IsoDep -> connection.transceive(data)
                            is NfcA -> connection.transceive(data)
                            is NfcF -> connection.transceive(data)
                            is NfcV -> connection.transceive(data)
                            else -> throw IOException("transceive needs a connected IsoDep, NfcA, NfcF or NfcV tag")
                        }
                        report(tag, operation, bytes = response)
                    }
                }
            } catch (error: Exception) {
                report(tag, operation, error = error)
            }
        }
    }

    /** The tag's Ndef, connected; the session's connection when it's one. */
    private fun ndef(tag: Long, found: Tag?): Ndef {
        val ndef = connections[tag] as? Ndef ?: found?.let(Ndef::get) ?: throw StatusException("NotNDEF")
        ensureConnected(ndef)
        return ndef
    }

    private fun ensureConnected(technology: TagTechnology) {
        if (!technology.isConnected) {
            // One technology connects at a time.
            connections.values.filter { it !== technology }.forEach { runCatching { it.close() } }
            technology.connect()
        }
    }

    fun isAvailable(tag: Long): Boolean = connections[tag]?.isConnected == true

    fun release(tag: Long) {
        val connection = connections.remove(tag)
        tags.remove(tag)
        if (connection != null) io.execute { runCatching { connection.close() } }
    }

    private fun report(tag: Long, operation: Int, status: Int = 0, capacity: Int = 0, bytes: ByteArray = ByteArray(0), error: Exception? = null) {
        val name = when (error) {
            null -> ""
            is StatusException -> error.message ?: ""
            is FormatException -> "android.nfc.FormatException"
            else -> error.javaClass.name
        }
        val message = if (error is StatusException) "" else error?.message ?: ""
        HostContext.main.post { NfcNatives.completed(tag, operation, status, capacity, bytes, name, message) }
    }

    /** A failure Swift's `NFCMapping` knows by name: ReadOnly, Capacity or NotNDEF. */
    private class StatusException(name: String) : Exception(name)

    private companion object {
        const val CONNECT = 0
        const val QUERY = 1
        const val READ = 2
        const val WRITE = 3
        const val LOCK = 4
        const val TRANSCEIVE = 5
    }
}

/** Reader mode's tags and the tag thread's results, on the main thread, for Swift's `NFCHub`. */
object NfcNatives {

    external fun discovered(session: Long, tag: Long, technologies: Array<String>, identifier: ByteArray,
                            historicalBytes: ByteArray, maximumTransceiveLength: Int)

    external fun completed(tag: Long, operation: Int, status: Int, capacity: Int, bytes: ByteArray, exception: String, message: String)
}
