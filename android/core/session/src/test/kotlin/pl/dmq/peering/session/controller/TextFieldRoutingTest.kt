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
import pl.dmq.peering.wire.FieldStatePayload
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.NormalizedPoint
import pl.dmq.peering.wire.ServerHello
import pl.dmq.peering.wire.TextFocusPayload

class TextFieldRoutingTest {
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

    private fun frame(kind: MessageKind, json: String) = Frame(kind, json.toByteArray())

    @Test
    fun `a focus report becomes a focus event`() {
        val events = router.route(frame(MessageKind.TextFocus, """{"isEditable":true}"""))

        assertEquals(listOf<SessionEvent>(SessionEvent.HostTextFocus(TextFocusPayload(true))), events)
    }

    @Test
    fun `a field report carries the text, the selection and the caret`() {
        val events = router.route(frame(MessageKind.FieldState, """{"text":"hello","selectionLocation":2,"selectionLength":1,"caret":{"x":0.5,"y":0.25}}"""))

        assertEquals(
            listOf<SessionEvent>(SessionEvent.HostFieldState(FieldStatePayload("hello", 2, 1, NormalizedPoint(0.5, 0.25)))),
            events,
        )
    }

    @Test
    fun `a field the computer could not read has no text and no caret`() {
        val events = router.route(frame(MessageKind.FieldState, """{"selectionLocation":0,"selectionLength":0}"""))

        assertEquals(listOf<SessionEvent>(SessionEvent.HostFieldState(FieldStatePayload(null, 0, 0, null))), events)
    }

    @Test
    fun `malformed reports are dropped`() {
        assertTrue(router.route(frame(MessageKind.TextFocus, "nope")).isEmpty())
        assertTrue(router.route(frame(MessageKind.FieldState, "{")).isEmpty())
    }

    @Test
    fun `a selection outside the text is pulled back inside it`() {
        val state = FieldStatePayload("abc", selectionLocation = 9, selectionLength = 4)
        assertEquals(3 until 3, state.selectionIn(3))
        assertEquals(1 until 3, FieldStatePayload("abc", 1, 99).selectionIn(3))
        assertEquals(0 until 0, FieldStatePayload("abc", -4, -1).selectionIn(3))
    }
}
