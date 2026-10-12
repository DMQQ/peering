package pl.dmq.peering.ui.wiring

import pl.dmq.peering.platform.net.UdpLane
import pl.dmq.peering.session.controller.ConnectTarget
import pl.dmq.peering.session.controller.SessionController

/** A session the phone has started, with the datagram socket it owns when it routes through the relay. */
internal class ActiveSession(
    val target: ConnectTarget,
    val controller: SessionController,
    private val lane: UdpLane?,
) {
    fun close() {
        controller.disconnect()
        lane?.close()
    }
}
