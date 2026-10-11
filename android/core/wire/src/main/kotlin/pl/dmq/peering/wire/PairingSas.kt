package pl.dmq.peering.wire

import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** Short authentication string pairing maths. See docs/protocol.md section 6. */
object PairingSas {
    const val COMMITMENT_DOMAIN = "MacCast-Pairing-commit-v1"
    const val SAS_DOMAIN = "MacCast-Pairing-SAS-v1"
    const val PROOF_DOMAIN = "MacCast-Pairing-proof-v1"

    internal const val SHA_256 = "SHA-256"

    fun commitment(ephemeralPublicKey: ByteArray, nonce: ByteArray): ByteArray {
        val digest = MessageDigest.getInstance(SHA_256)
        digest.update(COMMITMENT_DOMAIN.toByteArray(Charsets.UTF_8))
        digest.update(ephemeralPublicKey)
        digest.update(nonce)
        return digest.digest()
    }

    fun verifyCommitment(received: ByteArray, ephemeralPublicKey: ByteArray, nonce: ByteArray): Boolean =
        MessageDigest.isEqual(received, commitment(ephemeralPublicKey, nonce))
}

/**
 * Every exchanged field, in the fixed order of [serialized]. Each field is written as `u32 big-endian length` followed
 * by its bytes, so bytes cannot shift across a field boundary and produce the same digits.
 */
data class PairingTranscript(
    val protocolVersion: Int,
    val clientId: String,
    val serverId: String,
    val clientEphemeralPublicKey: ByteArray,
    val serverEphemeralPublicKey: ByteArray,
    val clientNonce: ByteArray,
    val serverNonce: ByteArray,
    val serverIdentityPublicKey: ByteArray,
) {
    init {
        require(protocolVersion in 0..MAX_U16) { "protocol version $protocolVersion does not fit in u16" }
    }

    fun serialized(): ByteArray {
        val out = ByteArrayOutputStream()
        out.writeField(PairingSas.SAS_DOMAIN.toByteArray(Charsets.UTF_8))
        out.writeField(byteArrayOf((protocolVersion ushr 8).toByte(), protocolVersion.toByte()))
        out.writeField(clientId.toByteArray(Charsets.UTF_8))
        out.writeField(serverId.toByteArray(Charsets.UTF_8))
        out.writeField(clientEphemeralPublicKey)
        out.writeField(serverEphemeralPublicKey)
        out.writeField(clientNonce)
        out.writeField(serverNonce)
        out.writeField(serverIdentityPublicKey)
        return out.toByteArray()
    }

    fun code(): String {
        val digest = MessageDigest.getInstance(PairingSas.SHA_256).digest(serialized())
        val value = ((digest[0].toLong() and 0xFF) shl 24) or
            ((digest[1].toLong() and 0xFF) shl 16) or
            ((digest[2].toLong() and 0xFF) shl 8) or
            (digest[3].toLong() and 0xFF)
        return (value % DIGIT_MODULUS).toString().padStart(DIGIT_COUNT, '0')
    }

    /** Shows that the confirming phone saw the host screen, where the QR carried the secret. */
    fun proof(secret: ByteArray): ByteArray {
        require(secret.isNotEmpty()) { "the pairing secret is empty" }
        val mac = Mac.getInstance(HMAC_SHA_256)
        mac.init(SecretKeySpec(secret, HMAC_SHA_256))
        mac.update(PairingSas.PROOF_DOMAIN.toByteArray(Charsets.UTF_8))
        return mac.doFinal(serialized())
    }

    fun verifyProof(received: ByteArray, secret: ByteArray): Boolean =
        MessageDigest.isEqual(received, proof(secret))

    private fun ByteArrayOutputStream.writeField(bytes: ByteArray) {
        val length = bytes.size
        write(length ushr 24)
        write(length ushr 16)
        write(length ushr 8)
        write(length)
        write(bytes)
    }

    private companion object {
        const val MAX_U16 = 0xFFFF
        const val DIGIT_MODULUS = 1_000_000L
        const val DIGIT_COUNT = 6
        const val HMAC_SHA_256 = "HmacSHA256"
    }
}
