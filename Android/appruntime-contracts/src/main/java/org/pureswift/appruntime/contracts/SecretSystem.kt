package org.pureswift.appruntime.contracts

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.File
import java.io.IOException
import java.security.GeneralSecurityException
import java.security.KeyStore
import java.security.MessageDigest
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * The app's secrets for Swift's `KeystoreSecretStore`
 * (Documentation/Plan.md §6.12): an AES-GCM key in the Android Keystore,
 * which never leaves it, and each secret encrypted with it in a file of
 * `noBackupFilesDir`, which isn't backed up. The file's name is a hash of
 * the secret's key, and the key itself is inside, encrypted with the value.
 *
 * Called on Swift's secrets queue, one call at a time. Each call returns its
 * value, or an empty one, and leaves a `KeychainError` raw value for
 * [error] on the same thread: 0 when it succeeded. [found] says whether
 * [value] found one. Nothing is logged.
 */
class SecretSystem {

    private val directory: File get() = File(HostContext.application.noBackupFilesDir, "appruntime-secrets")

    fun error(): Int = lastError.get() ?: 0

    fun found(): Boolean = lastFound.get() ?: false

    fun set(key: String, value: ByteArray) {
        secret {
            directory.mkdirs()
            val file = file(key)
            val partial = File(directory, file.name + ".new")
            partial.writeBytes(encrypt(key, value))
            if (!partial.renameTo(file)) throw IOException("the secret can't be kept")
        }
    }

    fun value(key: String): ByteArray = secret {
        lastFound.set(false)
        val file = file(key)
        if (!file.exists()) return@secret ByteArray(0)
        val (stored, value) = decrypt(file.readBytes())
        if (stored != key) return@secret ByteArray(0)
        lastFound.set(true)
        value
    } ?: ByteArray(0)

    fun remove(key: String) {
        secret {
            val file = file(key)
            if (file.exists() && !file.delete()) throw IOException("the secret can't be removed")
        }
    }

    fun removeAll() {
        secret {
            directory.listFiles()?.forEach { if (!it.delete()) throw IOException("a secret can't be removed") }
        }
    }

    /** The keys, in any order. A file that doesn't decrypt isn't one. */
    fun keys(): Array<String> = secret {
        val keys = ArrayList<String>()
        for (file in directory.listFiles() ?: emptyArray()) {
            if (file.name.endsWith(".new")) continue
            try {
                keys += decrypt(file.readBytes()).first
            } catch (error: AEADBadTagException) {
            }
        }
        keys.toTypedArray()
    } ?: emptyArray()

    private fun file(key: String): File {
        val digest = MessageDigest.getInstance("SHA-256").digest(key.toByteArray(Charsets.UTF_8))
        return File(directory, digest.joinToString("") { "%02x".format(it) })
    }

    /** The key's length, the key, and the value, encrypted: the IV first. */
    private fun encrypt(key: String, value: ByteArray): ByteArray {
        val keyBytes = key.toByteArray(Charsets.UTF_8)
        val plain = ByteArray(2 + keyBytes.size + value.size)
        plain[0] = (keyBytes.size shr 8).toByte()
        plain[1] = keyBytes.size.toByte()
        keyBytes.copyInto(plain, 2)
        value.copyInto(plain, 2 + keyBytes.size)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        return cipher.iv + cipher.doFinal(plain)
    }

    private fun decrypt(stored: ByteArray): Pair<String, ByteArray> {
        if (stored.size < IV + 2) throw AEADBadTagException("too short")
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, stored, 0, IV))
        val plain = cipher.doFinal(stored, IV, stored.size - IV)
        val length = ((plain[0].toInt() and 0xFF) shl 8) or (plain[1].toInt() and 0xFF)
        if (plain.size < 2 + length) throw AEADBadTagException("too short")
        val key = String(plain, 2, length, Charsets.UTF_8)
        return key to plain.copyOfRange(2 + length, plain.size)
    }

    /** The app's key in the Keystore, made the first time. */
    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (keyStore.getEntry(ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return generator.generateKey()
    }

    /** Runs a call, keeping its error for [error]. */
    private inline fun <T> secret(body: () -> T): T? {
        lastError.set(0)
        return try {
            body()
        } catch (error: AEADBadTagException) {
            // A file the key can't open: the Keystore lost the key, as when
            // the user removes the screen lock on some devices.
            lastError.set(UNAVAILABLE)
            null
        } catch (error: GeneralSecurityException) {
            lastError.set(UNAVAILABLE)
            null
        } catch (error: IOException) {
            lastError.set(UNAVAILABLE)
            null
        }
    }

    private companion object {
        const val KEYSTORE = "AndroidKeyStore"
        const val ALIAS = "org.pureswift.appruntime.secrets"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV = 12

        // KeychainError raw values.
        const val UNAVAILABLE = 2

        val lastError = ThreadLocal<Int>()
        val lastFound = ThreadLocal<Boolean>()
    }
}
