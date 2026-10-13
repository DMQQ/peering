package pl.dmq.peering.session.controller

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.connection.LivenessMonitor
import pl.dmq.peering.session.connection.SessionCommands
import pl.dmq.peering.session.ports.Clock
import pl.dmq.peering.session.ports.PeerAddress
import pl.dmq.peering.session.testing.FakeVideoSink
import pl.dmq.peering.session.video.SourceSelection
import pl.dmq.peering.session.video.VideoLanes
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.NormalizedPoint
import pl.dmq.peering.wire.ServerHello
import pl.dmq.peering.wire.WireJson

class PointerReportRoutingTest {
    private val clock = object : Clock {
        override fun monotonicSeconds() = 0.0

        override fun unixSeconds() = 0L
    }
    private val router = FrameRouter(
        liveness = LivenessMonitor(clock),
        commands = SessionCommands(ServerHello(serverID = "s", hostName = "h", protocolVersion = 20, alreadyPaired = true)),
        lanes = VideoLanes(FakeVideoSink(), clock, PeerAddress("relay", 1), ByteArray(16)),
        selection = SourceSelection(),
        agent = null,
        files = null,
        terminals = null,
    )

    private fun report(json: String) = Frame(MessageKind.PointerReport, json.toByteArray())

    @Test
    fun aReportBecomesAPointerEvent() {
        val point = NormalizedPoint(0.25, 0.75)
        val json = WireJson.encodeToString(NormalizedPoint.serializer(), point)

        assertEquals(listOf<SessionEvent>(SessionEvent.HostPointerMoved(point)), router.route(report(json)))
    }

    @Test
    fun aPointOutsideTheUnitSquareIsClamped() {
        val events = router.route(report("""{"x":1.5,"y":-2}"""))

        assertEquals(listOf<SessionEvent>(SessionEvent.HostPointerMoved(NormalizedPoint(1.0, 0.0))), events)
    }

    @Test
    fun aMalformedReportIsDropped() {
        assertTrue(router.route(report("not json")).isEmpty())
    }
}
