package pl.dmq.peering.billing

import java.security.MessageDigest

/**
 * The Play obfuscated account id that binds a purchase to this device: the SHA-256 of the device's public key, in lower
 * case hex. The relay compares it with the key of the client that presents the purchase.
 */
object ObfuscatedAccount {
    fun of(publicKey: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(publicKey).joinToString("") { "%02x".format(it) }
}
