package org.feverdreamtv.tsync.bridge

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.File
import java.io.FileOutputStream
import java.security.KeyStore
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * The vault's host keystore (android.md §4.1 item 7): each entry sealed with AES-GCM under one
 * non-exportable Android Keystore key that needs no user authentication, in a directory the
 * platform never backs up. The core calls it on its own threads; it never calls back into the core.
 */
object Keystore {
    private const val ALIAS = "tsync-vault"
    private const val IV_LENGTH = 12
    private const val TAG_LENGTH = 16

    /** Set before the library loads. */
    @Volatile
    lateinit var directory: File

    @Synchronized
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(ALIAS, null) as SecretKey?)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    /** A hash of the entry name: names hold `/`, and a domain's can be too long for a file name. */
    private fun file(name: ByteArray) =
        File(directory, MessageDigest.getInstance("SHA-256").digest(name).joinToString("") { "%02x".format(it) } + ".key")

    @JvmStatic
    @Synchronized
    fun put(name: ByteArray, entry: ByteArray) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        val sealed = cipher.iv + cipher.doFinal(entry)
        directory.mkdirs()
        val target = file(name)
        val partial = File(directory, target.name + ".partial")
        FileOutputStream(partial).use {
            it.write(sealed)
            it.fd.sync()
        }
        if (!partial.renameTo(target)) error("cannot write ${target.name}")
    }

    /** A file too short to hold a sealed entry is what a crash mid-write left: absent. */
    @JvmStatic
    @Synchronized
    fun get(name: ByteArray): ByteArray? {
        val sealed = file(name).takeIf { it.exists() }?.readBytes() ?: return null
        if (sealed.size < IV_LENGTH + TAG_LENGTH) return null
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, sealed, 0, IV_LENGTH))
        return cipher.doFinal(sealed, IV_LENGTH, sealed.size - IV_LENGTH)
    }

    @JvmStatic
    @Synchronized
    fun delete(name: ByteArray) {
        val target = file(name)
        if (target.exists() && !target.delete()) error("cannot delete ${target.name}")
    }
}
