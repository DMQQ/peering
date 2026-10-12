package pl.dmq.peering.session.controller

import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.clipboard.ClipboardContent
import pl.dmq.peering.session.clipboard.ClipboardDirection
import pl.dmq.peering.session.clipboard.ClipboardPush
import pl.dmq.peering.session.flows.ScriptedPairingHost
import pl.dmq.peering.wire.ClipboardPayload
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.PushClipboard
import pl.dmq.peering.wire.WireJson

class ClipboardSessionTest {
    @Test
    fun textTheUserSendsIsKeptAsGoingToTheComputer() = runTest {
        val rig = lanRig(ScriptedMac())
        rig.controller.connect()
        settle()

        rig.controller.send(PushClipboard("from the phone"))

        val entry = rig.controller.clipboardHistory.entries.value.single()
        assertEquals(ClipboardContent.Text("from the phone"), entry.content)
        assertEquals(ClipboardDirection.TO_COMPUTER, entry.direction)
    }

    @Test
    fun aRefusedSendIsNotKept() = runTest {
        val rig = lanRig(ScriptedMac())

        rig.controller.send(PushClipboard("too early"))

        assertTrue(rig.controller.clipboardHistory.entries.value.isEmpty())
    }

    @Test
    fun whatTheComputerSendsIsShownAndKeptAsComingFromIt() = runTest {
        val rig = lanRig(ScriptedMac())
        rig.controller.connect()
        settle()

        val payload = WireJson.encodeToString(ClipboardPayload.serializer(), ClipboardPayload(kind = "text", text = "from the mac"))
        rig.mac.connections.single().deliver(Frame(MessageKind.ClipboardContent, payload.toByteArray()))
        settle()
        advanceTimeBy(PUBLISH_MILLIS)
        runCurrent()

        assertEquals(ClipboardContent.Text("from the mac"), rig.controller.state.value.hostClipboard)
        val entry = rig.controller.clipboardHistory.entries.value.single()
        assertEquals(ClipboardDirection.FROM_COMPUTER, entry.direction)
    }

    @Test
    fun aPictureGoesOnlyToAHostThatDeclaredPicturesAndIsKept() = runTest {
        val png = ByteArray(40_000) { (it % 97).toByte() }
        val plain = lanRig(ScriptedMac())
        plain.controller.connect()
        settle()
        assertEquals(ClipboardPush.Unsupported, plain.controller.sendClipboardImage(png))
        assertTrue(plain.controller.clipboardHistory.entries.value.isEmpty())

        val capable = lanRig(ScriptedMac(declare = { it.copy(supportsClipboardImages = true) }))
        capable.controller.connect()
        settle()
        assertEquals(ClipboardPush.Sent, capable.controller.sendClipboardImage(png))
        settle()

        val chunks = capable.mac.connections.single().phoneFrames.ofKind(MessageKind.VideoChunk)
        assertTrue(chunks.size > 1)
        assertEquals(ClipboardContent.Image(png), capable.controller.clipboardHistory.entries.value.single().content)
    }

    @Test
    fun aPictureBeforeTheSessionIsReadyIsNotSent() = runTest {
        val rig = lanRig(ScriptedMac(declare = { it.copy(supportsClipboardImages = true) }))

        assertEquals(ClipboardPush.NotReady, rig.controller.sendClipboardImage(ByteArray(8)))
    }

    private fun TestScope.lanRig(mac: ScriptedMac): ControllerRig = ControllerRig(
        backgroundScope,
        testScheduler,
        ConnectTarget.Lan(ControllerRig.LAN_ADDRESS, ScriptedPairingHost.HOST_ID),
        mac,
    )

    private companion object {
        /** The link publishes its state on its quarter-second tick. */
        const val PUBLISH_MILLIS = 300L
    }
}
