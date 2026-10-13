package pl.dmq.peering.session.testing

import pl.dmq.peering.session.ports.Random

/** Every byte it returns has the same value, so a test can predict the ephemeral keys and nonces it produces. */
class FixedRandom(private val fill: Byte = 1) : Random {
    override fun bytes(count: Int): ByteArray = ByteArray(count) { fill }
}
