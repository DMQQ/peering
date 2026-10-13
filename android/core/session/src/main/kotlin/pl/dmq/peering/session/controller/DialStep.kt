package pl.dmq.peering.session.controller

import pl.dmq.peering.session.ports.PeerAddress
import kotlin.time.Duration

/** One way of reaching the host. A later step starts when [startsAfter] passes, or at once when every earlier step has failed. */
sealed interface DialStep {
    /** How long this step waits for earlier steps before starting alongside them, or null to start only after they all fail. */
    val startsAfter: Duration?

    /** The local network at [address]. [timeout] bounds the attempt: a remembered address is less sure than a seen one. */
    data class Lan(val address: PeerAddress, val timeout: Duration, override val startsAfter: Duration? = Duration.ZERO) : DialStep

    data class Relay(override val startsAfter: Duration?) : DialStep
}
