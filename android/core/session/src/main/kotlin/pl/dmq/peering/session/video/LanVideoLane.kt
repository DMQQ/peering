package pl.dmq.peering.session.video

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import pl.dmq.peering.session.controller.ControlConnector
import pl.dmq.peering.session.controller.ControlRoute
import pl.dmq.peering.session.controller.PictureFailure
import pl.dmq.peering.session.history.ByteTally
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
 * session is already authenticated, so this is opened only once the session is ready. It carries no handshake, so the
 * key the connection shows is compared with [expectedPeerKey], the host's pin; a lane to any other key is never used and
 * is not retried. A missing expected key fails the lane rather than trusting the address.
 */
internal class LanVideoLane(
    private val connector: ControlConnector,
    private val address: PeerAddress,
    private val expectedPeerKey: ByteArray?,
    sink: VideoSink,
    private val tally: ByteTally,
    private val mark: (String) -> Unit = {},
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
            val opened = try {
                attempt()
            } catch (mismatch: PeerKeyMismatch) {
                failure = PictureFailure.CouldNotOpen
                return
            }
            val wait = ladder.next()
            if (wait == null) {
                failure = if (opened) PictureFailure.Dropped else PictureFailure.CouldNotOpen
                return
            }
            mark("video lane ${if (opened) "closed" else "did not open"}, trying again in $wait")
            delay(wait)
        }
    }

    /** One connection from dial to end. True when it opened, whatever ended it. */
    private suspend fun attempt(): Boolean {
        mark("video lane dialling")
        val transport = try {
            connector.open(ControlRoute.Video(address))
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            mark("video lane dial failed: ${error::class.simpleName}")
            return false
        }
        mark("video lane open")
        val observed = transport.peerPublicKey()
        if (expectedPeerKey == null || observed == null || !observed.contentEquals(expectedPeerKey)) {
            transport.close()
            throw PeerKeyMismatch()
        }
        try {
            val hello = FrameEncoder.encode(MessageKind.ConnectionRole, byteArrayOf(ConnectionRole.Video.byte.toByte()))
            transport.send(hello)
            tally.addSent(hello.size)
            mark("video lane role frame sent")
            val decoder = FrameDecoder()
            var firstBytes = true
            var firstConfig = true
            var firstFrame = true
            transport.received.collect { chunk ->
                if (firstBytes) mark("video lane first bytes")
                firstBytes = false
                tally.addReceived(chunk.size)
                decoder.push(chunk)
                while (true) {
                    val frame: Frame = decoder.next() ?: break
                    if (frame.kind == MessageKind.VideoConfig && firstConfig) mark("video config received")
                    if (frame.kind == MessageKind.VideoConfig) firstConfig = false
                    if (frame.kind == MessageKind.VideoFrame && firstFrame) mark("first video frame received")
                    if (frame.kind == MessageKind.VideoFrame) firstFrame = false
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

private class PeerKeyMismatch : Exception()
