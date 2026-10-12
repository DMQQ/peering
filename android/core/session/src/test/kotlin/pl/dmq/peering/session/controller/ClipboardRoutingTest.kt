package pl.dmq.peering.session.controller

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.clipboard.ClipboardContent
import pl.dmq.peering.session.connection.LivenessMonitor
import pl.dmq.peering.session.connection.SessionCommands
import pl.dmq.peering.session.ports.Clock
import pl.dmq.peering.session.ports.PeerAddress
import pl.dmq.peering.session.testing.FakeVideoSink
import pl.dmq.peering.session.video.SourceSelection
import pl.dmq.peering.session.video.VideoLanes
import pl.dmq.peering.wire.CONTROL_CHUNK_SIZE
import pl.dmq.peering.wire.ClipboardPayload
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.ServerHello
import pl.dmq.peering.wire.VideoChunkEncoder
import pl.dmq.peering.wire.WireJson
import pl.dmq.peering.wire.toBase64

class ClipboardRoutingTest {
    private val clock = object : Clock {
        override fun monotonicSeconds() = 0.0

        override fun unixSeconds() = 0L
    }
    private val sink = FakeVideoSink()
    private val router = FrameRouter(
        liveness = LivenessMonitor(clock),
        commands = SessionCommands(ServerHello(serverID = "s", hostName = "h", protocolVersion = 20, alreadyPaired = true)),
        lanes = VideoLanes(sink, clock, PeerAddress("relay", 1), ByteArray(16)),
        selection = SourceSelection(),
        agent = null,
        files = null,
        terminals = null,
    )

    private fun payloadFrame(payload: ClipboardPayload) =
        WireJson.encodeToString(ClipboardPayload.serializer(), payload).toByteArray()

    private fun content(events: List<SessionEvent>) = (events.single() as SessionEvent.HostClipboard).content

    @Test
    fun textArrivesAsText() {
        val frame = Frame(MessageKind.ClipboardContent, payloadFrame(ClipboardPayload(kind = "text", text = "hi")))

        assertEquals(ClipboardContent.Text("hi"), content(router.route(frame)))
    }

    @Test
    fun aChunkedPictureIsReassembledAndNeverReachesThePictureStream() {
        val png = ByteArray(100_000) { (it % 200).toByte() }
        val body = payloadFrame(ClipboardPayload(kind = "image", image = png.toBase64()))
        val chunks = VideoChunkEncoder.encode(MessageKind.ClipboardContent, body, 3, CONTROL_CHUNK_SIZE)

        val events = chunks.flatMap(router::route)

        assertTrue(chunks.size > 1)
        assertEquals(ClipboardContent.Image(png), content(events))
        assertTrue(sink.frames.isEmpty() && sink.configs.isEmpty())
    }

    @Test
    fun aPictureThatIsNotValidShowsAsNothingToCopy() {
        val frame = Frame(MessageKind.ClipboardContent, payloadFrame(ClipboardPayload(kind = "image", image = "!!!")))

        assertEquals(ClipboardContent.Text(""), content(router.route(frame)))
    }
}
