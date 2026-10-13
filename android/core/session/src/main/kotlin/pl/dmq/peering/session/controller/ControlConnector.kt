package pl.dmq.peering.session.controller

import pl.dmq.peering.session.ports.ControlTransport

/**
 * Opens one control connection along [route]. The platform owns the socket and the TLS handshake, so a connector is
 * the only place that knows how to write a relay token before TLS. Throws when the connection cannot be made.
 */
fun interface ControlConnector {
    suspend fun open(route: ControlRoute): ControlTransport
}
