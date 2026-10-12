package pl.dmq.peering.widget

import java.io.File
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * A secret the widgets put in the intent they send to the exported main activity, because any app can send that
 * activity a `peering://` link and nothing else says who sent it. It is made once per install and never leaves the
 * app's private storage.
 */
object LinkNonce {
    const val EXTRA = "pl.dmq.peering.link_nonce"
    private const val FILE_NAME = "link_nonce"
    private const val BYTES = 32

    /** The install's nonce from [directory], made and saved on first use. */
    @Synchronized
    fun load(directory: File, random: () -> ByteArray = ::secureBytes): String {
        val file = File(directory, FILE_NAME)
        file.takeIf { it.isFile }?.readText()?.takeIf { it.isNotEmpty() }?.let { return it }
        val made = random().joinToString("") { "%02x".format(it) }
        directory.mkdirs()
        file.writeText(made)
        return made
    }

    /** True only for the install's own nonce. Compared in constant time. */
    fun accepts(expected: String, presented: String?): Boolean =
        presented != null && MessageDigest.isEqual(expected.toByteArray(), presented.toByteArray())

    private fun secureBytes(): ByteArray = ByteArray(BYTES).also { SecureRandom().nextBytes(it) }
}
