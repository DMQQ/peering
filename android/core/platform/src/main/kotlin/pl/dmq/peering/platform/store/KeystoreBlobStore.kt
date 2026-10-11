package pl.dmq.peering.platform.store

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.GeneralSecurityException
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

private const val ANDROID_KEY_STORE = "AndroidKeyStore"
private const val KEY_ALIAS = "pl.dmq.peering.blobs"
private const val TRANSFORMATION = "AES/GCM/NoPadding"
private const val IV_SIZE = 12
private const val TAG_BITS = 128

/**
 * Stores each blob as AES-GCM ciphertext under a key that never leaves the Keystore, in a file under [directory].
 * The file is replaced whole, through a temporary file, so a crash leaves the previous blob intact.
 */
class KeystoreBlobStore(private val directory: File) : BlobStore {
    override fun get(name: String): ByteArray? {
        val file = fileFor(name)
        if (!file.isFile) return null
        return try {
            val bytes = file.readBytes()
            if (bytes.size <= IV_SIZE) return null
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(TAG_BITS, bytes.copyOf(IV_SIZE)))
            cipher.doFinal(bytes, IV_SIZE, bytes.size - IV_SIZE)
        } catch (_: IOException) {
            null
        } catch (_: GeneralSecurityException) {
            null
        }
    }

    override fun put(name: String, value: ByteArray): Boolean {
        val target = fileFor(name)
        val temporary = File(directory, "$name.tmp")
        return try {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.ENCRYPT_MODE, secretKey())
            val sealed = cipher.iv + cipher.doFinal(value)
            temporary.writeBytes(sealed)
            Files.move(temporary.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
            true
        } catch (_: IOException) {
            false
        } catch (_: GeneralSecurityException) {
            false
        }
    }

    private fun fileFor(name: String): File = File(directory, name)

    @Synchronized
    private fun secretKey(): SecretKey {
        val store = KeyStore.getInstance(ANDROID_KEY_STORE).apply { load(null) }
        (store.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val spec = KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .build()
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEY_STORE)
            .apply { init(spec) }
            .generateKey()
    }
}
