package pl.dmq.peering.session.relay

import pl.dmq.peering.session.ports.PeerAddress
import pl.dmq.peering.wire.Token
import pl.dmq.peering.wire.hexToBytes

/** Where the relay put a granted session: the control socket to dial and the datagram lane to use. */
class RelaySession(
    val control: PeerAddress,
    val video: PeerAddress,
    controlToken: Token,
    videoToken: Token,
) {
    val videoTokenBytes: ByteArray = videoToken.toHex().hexToBytes()

    private val controlTokenBytes: ByteArray = controlToken.toHex().hexToBytes()

    /** The first bytes written on the control socket, before the TLS handshake. */
    fun controlHandoff(): ControlHandoff = ControlHandoff(control, controlTokenBytes)
}
