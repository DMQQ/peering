package pl.dmq.peering.platform.net

import java.security.MessageDigest
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.security.interfaces.ECPublicKey
import java.util.concurrent.atomic.AtomicReference
import javax.net.ssl.X509TrustManager
import pl.dmq.peering.platform.identity.uncompressedPoint

private const val P256_FIELD_BITS = 256

/**
 * Trust is decided by the pin, not by a certificate authority, so the chain is never validated. The leaf key is
 * recorded before the pin is compared, so first pairing can read it. Without a pin every peer is accepted; nothing
 * is trusted until the caller pins the recorded key.
 */
class PinningTrustManager(private val pin: ByteArray?) : X509TrustManager {
    private val observed = AtomicReference<ByteArray?>(null)

    /** The 65-byte key of the leaf the peer presented, or null before a handshake has reached certificate checks. */
    fun observedKey(): ByteArray? = observed.get()

    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
        checkPeer(chain)
    }

    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) {
        checkPeer(chain)
    }

    override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()

    private fun checkPeer(chain: Array<out X509Certificate>?) {
        val presented = leafPoint(chain)
        observed.set(presented)
        if (!pinAccepts(pin, presented)) throw CertificateException("peer key does not match the pinned key")
    }

    private fun leafPoint(chain: Array<out X509Certificate>?): ByteArray {
        val leaf = chain?.firstOrNull() ?: throw CertificateException("peer presented no certificate")
        val key = leaf.publicKey as? ECPublicKey ?: throw CertificateException("peer key is not an EC key")
        if (key.params.curve.field.fieldSize != P256_FIELD_BITS) {
            throw CertificateException("peer key is not P-256")
        }
        return uncompressedPoint(key)
    }
}

/** Constant time, because the peer controls the presented key. A null pin is first pairing, which accepts. */
internal fun pinAccepts(pin: ByteArray?, presented: ByteArray): Boolean =
    pin == null || MessageDigest.isEqual(pin, presented)
