package pl.dmq.peering

import java.security.SecureRandom
import pl.dmq.peering.session.ports.Random

class SecureRandomSource : Random {
    private val source = SecureRandom()

    override fun bytes(count: Int): ByteArray = ByteArray(count).also(source::nextBytes)
}
