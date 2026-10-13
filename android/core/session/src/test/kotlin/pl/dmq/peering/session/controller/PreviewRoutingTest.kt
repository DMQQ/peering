package pl.dmq.peering.session.controller

import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.connection.LivenessMonitor
import pl.dmq.peering.session.connection.SessionCommands
import pl.dmq.peering.session.ports.Clock
import pl.dmq.peering.session.ports.PeerAddress
import pl.dmq.peering.session.preview.PreviewProxyClient
import pl.dmq.peering.session.testing.FakeVideoSink
import pl.dmq.peering.session.video.SourceSelection
import pl.dmq.peering.session.video.VideoLanes
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.PreviewProxyCommand
import pl.dmq.peering.wire.PreviewProxyEvent
import pl.dmq.peering.wire.ServerHello

class PreviewRoutingTest {
    private val clock = object : Clock {
        override fun monotonicSeconds() = 0.0

        override fun unixSeconds() = 0L
    }
    private val sent = mutableListOf<PreviewProxyCommand>()
    private val preview = PreviewProxyClient { sent += it; true }

    private fun router(preview: PreviewProxyClient?) = FrameRouter(
        liveness = LivenessMonitor(clock),
        commands = SessionCommands(ServerHello(serverID = "s", hostName = "h", protocolVersion = 20, alreadyPaired = true)),
        lanes = VideoLanes(FakeVideoSink(), clock, PeerAddress("relay", 1), ByteArray(16)),
        selection = SourceSelection(),
        agent = null,
        files = null,
        terminals = null,
        preview = preview,
    )

    private fun frame(json: String) = Frame(MessageKind.PreviewEvent, json.toByteArray())

    @Test
    fun aPreviewEventReachesTheRequestWaitingForIt() = runTest(UnconfinedTestDispatcher()) {
        val events = mutableListOf<PreviewProxyEvent>()
        val job = launch { preview.fetch(3000, "GET", "/").toList(events) }
        val id = (sent.single() as PreviewProxyCommand.Fetch).request.id
        val router = router(preview)
        assertTrue(router.route(frame("""{"head":{"id":$id,"status":200,"headers":[]}}""")).isEmpty())
        router.route(frame("""{"end":{"id":$id,"truncated":false}}"""))
        job.join()
        assertEquals(listOf("Head", "End"), events.map { it::class.simpleName })
    }

    @Test
    fun anEventNobodyCanReadOrUseIsDropped() {
        assertTrue(router(preview).route(frame("not json")).isEmpty())
        assertTrue(router(null).route(frame("""{"end":{"id":1,"truncated":false}}""")).isEmpty())
    }
}
