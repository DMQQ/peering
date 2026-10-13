package pl.dmq.peering.session.relay

import pl.dmq.peering.session.ports.PeerAddress

/**
 * Looks for a path straight to the Mac while the picture comes over the relay. It probes every 250 ms for the first
 * twelve attempts, then every five seconds, and asks the relay for the address every twelve attempts, since "not
 * known yet" is the ordinary first answer. Driven by [tick] with monotonic seconds, so tests need no real time.
 */
class DirectPathProber {
    var state: DirectPathState = DirectPathState.NotTried
        private set

    /** Where probes go. The address of the last authenticated datagram wins over a lookup. */
    var destination: PeerAddress? = null
        private set

    private var reported: DirectPathState = DirectPathState.NotTried
    private var nextStepAt: Double? = null
    private var stepsTaken = 0

    fun tick(now: Double): List<ProbeAction> {
        val actions = mutableListOf<ProbeAction>()
        if (state != reported) {
            reported = state
            actions += ProbeAction.Report(state)
        }
        nextStepAt?.let { if (now < it) return actions }

        val step = stepsTaken
        stepsTaken += 1
        nextStepAt = now + if (stepsTaken <= FAST_ATTEMPTS) FAST_INTERVAL_SECONDS else SLOW_INTERVAL_SECONDS
        if (step % REASK_EVERY_ATTEMPTS == 0) actions += ProbeAction.AskRelay
        destination?.let { actions += ProbeAction.SendProbe(it) }
        return actions
    }

    /** The relay's answer. A usable address becomes the probe destination; an unusable one is reported and ignored. */
    fun onPeerAddress(host: String, port: Int) {
        val address = PeerAddress(host, port)
        if (!isUsable(address)) {
            if (state !is DirectPathState.Open) state = DirectPathState.AddressUnusable(address)
            return
        }
        destination = address
        if (state !is DirectPathState.Open) state = DirectPathState.Probing(address)
    }

    /** The relay has no address yet, or none at all. */
    fun onPeerAddressUnknown() {
        if (state !is DirectPathState.Open) state = DirectPathState.NoAddress
    }

    /** A probe or any other datagram authenticated from [source]: that source is where the Mac hears us. */
    fun onAuthenticatedDatagram(source: PeerAddress) {
        destination = source
        state = DirectPathState.Open(source)
    }

    private fun isUsable(address: PeerAddress): Boolean =
        address.host.isNotBlank() && address.port in MIN_PORT..MAX_PORT

    private companion object {
        const val FAST_ATTEMPTS = 12
        const val REASK_EVERY_ATTEMPTS = 12
        const val FAST_INTERVAL_SECONDS = 0.25
        const val SLOW_INTERVAL_SECONDS = 5.0
        const val MIN_PORT = 1
        const val MAX_PORT = 65_535
    }
}
