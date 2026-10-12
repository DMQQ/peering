package pl.dmq.peering.ui.wiring

import java.net.InetSocketAddress
import java.net.Socket
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import pl.dmq.peering.platform.net.TlsFactory
import pl.dmq.peering.session.controller.ControlConnector
import pl.dmq.peering.session.controller.ControlRoute
import pl.dmq.peering.session.ports.ControlTransport

/** Dials the control connection over TLS: straight to the Mac, or through the relay with the token written first. */
internal class ControlSockets(private val tls: TlsFactory) : ControlConnector {
    override suspend fun open(route: ControlRoute): ControlTransport = withContext(Dispatchers.IO) {
        when (route) {
            is ControlRoute.Direct -> tls.open(route.address.host, route.address.port, pin = null, timeoutMs = TIMEOUT_MS)
            is ControlRoute.Relayed -> openRelayed(route)
        }
    }

    private fun openRelayed(route: ControlRoute.Relayed): ControlTransport {
        val address = route.handoff.address
        val raw = Socket()
        try {
            raw.connect(InetSocketAddress(address.host, address.port), TIMEOUT_MS)
        } catch (failure: Exception) {
            raw.close()
            throw failure
        }
        return tls.openOverToken(raw, route.handoff.token, address.host, address.port, pin = null, timeoutMs = TIMEOUT_MS)
    }

    private companion object {
        const val TIMEOUT_MS = 10_000
    }
}
