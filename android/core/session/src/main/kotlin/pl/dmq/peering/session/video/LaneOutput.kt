package pl.dmq.peering.session.video

import pl.dmq.peering.session.ports.PeerAddress
import pl.dmq.peering.wire.Frame

/** Something a lane asks its owner to do: write to the control connection, send a datagram, or show a note. */
sealed interface LaneOutput {
    data class SendControl(val frame: Frame) : LaneOutput

    class SendDatagram(val bytes: ByteArray, val destination: PeerAddress) : LaneOutput

    data class Note(val text: String) : LaneOutput
}
