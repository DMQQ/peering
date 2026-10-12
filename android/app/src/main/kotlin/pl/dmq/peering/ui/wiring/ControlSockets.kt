package pl.dmq.peering.ui.wiring

import pl.dmq.peering.DebugLog
import java.net.InetSocketAddress
import java.net.Socket
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import pl.dmq.peering.platform.net.TlsFactory
import pl.dmq.peering.session.controller.ControlConnector
import pl.dmq.peering.session.controller.ControlRoute
import pl.dmq.peering.session.ports.ControlTransport
import pl.dmq.peering.session.ports.PeerAddress

/** Dials a connection over TLS: the control connection or the local picture lane straight to the Mac, or through the relay with the token written first. */
internal class ControlSockets(private val tls: TlsFactory) : ControlConnector {
    override suspend fun open(route: ControlRoute): ControlTransport = withContext(Dispatchers.IO) {
        val transport = when (route) {
            is ControlRoute.Direct -> openDirect(route.address)
            is ControlRoute.Video -> openDirect(route.address)
            is ControlRoute.Relayed -> openRelayed(route)
        }
        // A blocking connect cannot be interrupted, so a session ended meanwhile would otherwise leave this socket open.
        try {
            ensureActive()
        } catch (cancelled: CancellationException) {
            transport.close()
            throw cancelled
        }
        transport
    }

    private fun openDirect(address: PeerAddress): ControlTransport {
        DebugLog.d(TAG) { "connecting directly" }
        return try {
            tls.open(address.host, address.port, pin = null, timeoutMs = TIMEOUT_MS)
        } catch (failure: Exception) {
            DebugLog.w(TAG, { "connecting directly failed" })
            throw failure
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
        const val TAG = "PeeringConnect"
    }
}
