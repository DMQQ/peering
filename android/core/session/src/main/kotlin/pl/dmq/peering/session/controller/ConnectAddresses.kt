package pl.dmq.peering.session.controller

import pl.dmq.peering.session.ports.PeerAddress
import java.net.ConnectException

/** Which addresses a direct connection tries for a discovered host, and when a failure is worth the next one. */
internal object ConnectAddresses {
    const val DEFAULT_PORT = 51515

    /** The resolved address first, then the protocol's default port on the same host when that differs. */
    fun candidates(resolved: PeerAddress): List<PeerAddress> =
        listOf(resolved, resolved.copy(port = DEFAULT_PORT)).distinct()

    /** True when something answered at the address and said no, which a stale advertised port does. */
    fun refused(failure: Throwable): Boolean =
        generateSequence(failure) { it.cause?.takeIf { cause -> cause !== it } }.any { it is ConnectException }
}
