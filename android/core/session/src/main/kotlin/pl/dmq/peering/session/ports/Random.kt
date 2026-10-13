package pl.dmq.peering.session.ports

/** A source of cryptographically secure random bytes. */
interface Random {
    /** [count] fresh random bytes. */
    fun bytes(count: Int): ByteArray
}
