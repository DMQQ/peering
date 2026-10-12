package pl.dmq.peering.session.controller

import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

/** Chooses the order of routes to a host: the local network first, the relay only behind it. */
object DialPlanner {
    /** How long a host just seen on the network is given to answer before the relay is tried. */
    val SEEN_TIMEOUT: Duration = 10.seconds

    /** A remembered address may be stale, so it is given less time. */
    val REMEMBERED_TIMEOUT: Duration = 3.seconds

    /**
     * A remembered address is dialled with the relay racing behind it after this head start. A phone that has just
     * woken its radio can take a second to open a socket on the same network, and a relay that wins that race keeps
     * the whole session off the local network.
     */
    val RELAY_HEAD_START: Duration = 1500.milliseconds

    /** The steps to try, in order. Empty when no route is allowed, which the caller reports as the host not being found. */
    fun plan(inputs: DialInputs): List<DialStep> {
        val relay = DialStep.Relay(startsAfter = Duration.ZERO).takeIf { inputs.relayAllowed }
        if (inputs.pairElsewhere) return listOfNotNull(relay)
        inputs.discovered?.let { seen ->
            return listOfNotNull(DialStep.Lan(seen, SEEN_TIMEOUT), relay?.copy(startsAfter = null))
        }
        inputs.remembered?.let { earlier ->
            return listOfNotNull(DialStep.Lan(earlier, REMEMBERED_TIMEOUT), relay?.copy(startsAfter = RELAY_HEAD_START))
        }
        return listOfNotNull(relay)
    }
}
