package pl.dmq.peering.ui.wiring

import pl.dmq.peering.platform.net.OkHttpSignalling
import pl.dmq.peering.session.ports.Signalling
import pl.dmq.peering.wire.RelayClientMessage
import pl.dmq.peering.wire.RelayServerMessage

/** The relay's signalling socket, opened by the first request that needs it. A failed open is tried again next time. */
internal class RelaySignallingLink(private val socket: OkHttpSignalling) : Signalling {
    private var open = false

    override suspend fun send(message: RelayClientMessage) {
        ensureOpen()
        socket.send(message)
    }

    override suspend fun receive(): RelayServerMessage {
        ensureOpen()
        return socket.receive()
    }

    private suspend fun ensureOpen() {
        if (open) return
        socket.connect()
        open = true
    }
}
