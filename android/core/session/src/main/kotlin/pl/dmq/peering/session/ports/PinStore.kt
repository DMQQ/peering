package pl.dmq.peering.session.ports

/** The host keys this device has paired with, by host id. */
interface PinStore {
    /** The 65-byte key pinned for [hostId], or null when the host is not paired. */
    fun pin(hostId: String): ByteArray?

    /** Pins [key] for [hostId]. False when the write did not persist, so the pairing must not count as done. */
    fun record(hostId: String, key: ByteArray): Boolean

    /** Forgets the pin for [hostId]. False when the removal did not persist. */
    fun remove(hostId: String): Boolean
}
