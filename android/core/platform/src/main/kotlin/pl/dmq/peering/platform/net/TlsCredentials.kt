package pl.dmq.peering.platform.net

import java.security.PrivateKey
import java.security.cert.X509Certificate

/** The certificate and key this device presents in TLS. The key stays wherever the platform keeps it. */
interface TlsCredentials {
    /** The certificate chain, leaf first. */
    fun certificateChain(): List<X509Certificate>

    /** The private key matching the leaf certificate. */
    fun privateKey(): PrivateKey
}
