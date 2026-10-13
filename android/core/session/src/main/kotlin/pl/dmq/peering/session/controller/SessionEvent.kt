package pl.dmq.peering.session.controller

import pl.dmq.peering.session.clipboard.ClipboardContent
import pl.dmq.peering.session.ports.PeerAddress
import pl.dmq.peering.session.video.LaneOutput
import pl.dmq.peering.wire.FieldStatePayload
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.NormalizedPoint
import pl.dmq.peering.wire.RemoteCommand
import pl.dmq.peering.wire.TextFocusPayload

/** What routing a frame asks the live link to do. The link applies them in order. */
sealed interface SessionEvent {
    /** Write this frame on the control connection. */
    data class Send(val frame: Frame) : SessionEvent

    /** Queue this command for the next coalesced write. */
    data class Offer(val command: RemoteCommand) : SessionEvent

    /** Send a sealed datagram on the relay's video socket. */
    class Datagram(val bytes: ByteArray, val destination: PeerAddress) : SessionEvent

    /** A standing notice from the host. A null [message] clears it. */
    data class Notice(val message: String?) : SessionEvent

    /** The host answered a clipboard request. Empty text means its clipboard held nothing the phone can take. */
    data class HostClipboard(val content: ClipboardContent) : SessionEvent

    /** The computer reported where its pointer is, after something other than this client moved it. */
    data class HostPointerMoved(val point: NormalizedPoint) : SessionEvent

    /** The computer's keyboard focus moved to or from a text field. */
    data class HostTextFocus(val focus: TextFocusPayload) : SessionEvent

    /** What the focused text field holds and where its caret is. */
    data class HostFieldState(val state: FieldStatePayload) : SessionEvent

    /** The link must end with [end]. */
    data class Finish(val end: LinkEnd) : SessionEvent
}

internal fun List<LaneOutput>.asEvents(): List<SessionEvent> = mapNotNull { output ->
    when (output) {
        is LaneOutput.SendControl -> SessionEvent.Send(output.frame)
        is LaneOutput.SendDatagram -> SessionEvent.Datagram(output.bytes, output.destination)
        is LaneOutput.Note -> null
    }
}
