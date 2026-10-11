package pl.dmq.peering.session.relay

import pl.dmq.peering.session.ports.PeerAddress
import pl.dmq.peering.wire.Token

/** Write [token] to a fresh TCP connection to [address], then run the TLS client handshake on the same socket. */
class ControlHandoff(val address: PeerAddress, val token: ByteArray) {
    init {
        require(token.size == Token.SIZE) { "a control token is ${Token.SIZE} bytes" }
    }
}
