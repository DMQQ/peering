package pl.dmq.peering.session.controller

import pl.dmq.peering.session.ports.PeerAddress

/**
 * What is known when the user asks to reach a paired host. [discovered] is an address seen on the network now,
 * [remembered] one seen on an earlier day. [pairElsewhere] is the user choosing to skip the local network.
 */
data class DialInputs(
    val discovered: PeerAddress?,
    val remembered: PeerAddress?,
    val relayAllowed: Boolean,
    val pairElsewhere: Boolean = false,
)
