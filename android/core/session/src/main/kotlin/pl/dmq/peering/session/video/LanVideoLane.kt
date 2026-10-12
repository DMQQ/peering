package pl.dmq.peering.session.video

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import pl.dmq.peering.session.controller.ControlConnector
import pl.dmq.peering.session.controller.ControlRoute
import pl.dmq.peering.session.controller.PictureFailure
import pl.dmq.peering.session.ports.PeerAddress
import pl.dmq.peering.session.ports.VideoSink
import pl.dmq.peering.wire.ConnectionRole
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.FrameDecoder
import pl.dmq.peering.wire.FrameEncoder
import pl.dmq.peering.wire.MessageKind

/**
 * The picture of a local session: a second TCP connection to the computer whose first frame names it a video
 * connection. The computer starts streaming when it has read that frame, and refuses the connection unless the control
 * session is already authenticated, so this is opened only once the session is ready. It carries no handshake.
 */
internal class LanVideoLane(
    private val connector: ControlConnector,
    private val address: PeerAddress,
    sink: VideoSink,
) {
    private val router = VideoPictureRouter(sink)
    private var ladder = VideoReconnectLadder()

    /** Why the lane gave up, or null while it is running or has not started. */
    var failure: PictureFailure? = null
        private set

    /** Forgets an earlier failure and starts the ladder over, so a state read before [run] is scheduled is already fresh. */
    fun reset() {
        failure = null
        ladder = VideoReconnectLadder()
    }

    /** Opens the connection and reopens it down the ladder whenever it ends, until the ladder is spent. */
    suspend fun run() {
        while (true) {
            val opened = attempt()
            val wait = ladder.next()
            if (wait == null) {
                failure = if (opened) PictureFailure.Dropped else PictureFailure.CouldNotOpen
                return
            }
            delay(wait)
        }
    }

    /** One connection from dial to end. True when it opened, whatever ended it. */
    private suspend fun attempt(): Boolean {
        val transport = try {
            connector.open(ControlRoute.Video(address))
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            return false
        }
        try {
            transport.send(FrameEncoder.encode(MessageKind.ConnectionRole, byteArrayOf(ConnectionRole.Video.byte.toByte())))
            val decoder = FrameDecoder()
            transport.received.collect { chunk ->
                decoder.push(chunk)
                while (true) {
                    val frame: Frame = decoder.next() ?: break
                    if (router.deliver(frame)) ladder.reset()
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            // A broken or refused connection reads the same as one the computer closed: the ladder decides what is next.
        } finally {
            transport.close()
        }
        return true
    }
}
