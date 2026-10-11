package pl.dmq.peering.session.ports

/** This device's long-term identity, as peers see it. The private key never leaves the platform. */
interface DeviceIdentity {
    /** The UUID string this device presents to peers. */
    val clientId: String

    /** The 65-byte uncompressed P-256 public key. */
    val publicKey: ByteArray

    /** Signs [message] with the private key. */
    fun sign(message: ByteArray): ByteArray
}
