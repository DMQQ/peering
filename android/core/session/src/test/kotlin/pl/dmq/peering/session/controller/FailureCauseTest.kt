@file:OptIn(ExperimentalCoroutinesApi::class)

package pl.dmq.peering.session.controller

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.connection.FailureReason
import pl.dmq.peering.session.flows.ScriptedPairingHost
import pl.dmq.peering.session.ports.PeerAddress
import pl.dmq.peering.session.testing.FakePinStore
import pl.dmq.peering.wire.MessageKind

/** Each way a connection can fail reaches the screen as its own failure, with the text the exception gave. */
class FailureCauseTest {
    private val stale = PeerAddress("10.9.9.9", 51599)

    @Test
    fun aHostNobodySeesOnTheNetworkIsHostNotFoundAndLogged() = runTest {
        val rig = rig(ConnectTarget.Pairing(ScriptedPairingHost.HOST_ID), nobodyDiscovered = true)
        rig.controller.connect()
        advanceTimeBy(11_000)
        runCurrent()

        assertEquals(SessionFailure.HostNotFound, failure(rig))
        assertTrue(rig.logged.any { "not seen" in it })
    }

    @Test
    fun aRefusedConnectionIsRefusedAndNeverMistakenForUnreachable() = runTest {
        val rig = rig(ConnectTarget.Lan(stale))
        rig.refusing += stale
        rig.refusing += stale.copy(port = 51515)
        rig.controller.connect()
        advanceTimeBy(100)
        runCurrent()

        assertEquals(ConnectFailureKind.Refused, (failure(rig) as SessionFailure.ConnectionFailed).kind)
        assertTrue(rig.logged.any { "Refused" in it })
    }

    @Test
    fun aHostWhoseKeyDoesNotMatchThePinIsAKeyMismatchThatCannotBeRetried() = runTest {
        val pins = FakePinStore(mapOf(ScriptedPairingHost.HOST_ID to ByteArray(65) { 0x1 }))
        val rig = rig(ConnectTarget.Lan(ControllerRig.LAN_ADDRESS, ScriptedPairingHost.HOST_ID), pins = pins)
        rig.controller.connect()
        advanceTimeBy(1_000)
        runCurrent()

        val phase = rig.controller.state.value.phase as SessionPhase.Failed
        assertEquals(SessionFailure.Handshake(FailureReason.PinMismatch(ScriptedPairingHost.HOST_ID)), phase.reason)
        assertFalse(phase.canRetry)
    }

    @Test
    fun aHostThatClosesDuringTheHandshakeSaysWhereItClosed() = runTest {
        val rig = rig(ConnectTarget.Lan(ControllerRig.LAN_ADDRESS, ScriptedPairingHost.HOST_ID))
        rig.mac.dropsOn = MessageKind.ClientHello
        rig.controller.connect()
        advanceTimeBy(1_000)
        runCurrent()

        val reason = failure(rig) as SessionFailure.ConnectionFailed
        assertEquals(ConnectFailureKind.Closed, reason.kind)
        assertEquals("The host closed the connection during the handshake", reason.cause)
    }

    @Test
    fun aHostThatGoesSilentWhileApprovingSaysSo() = runTest {
        val mac = ScriptedMac(alreadyPaired = false)
        mac.silentOn = MessageKind.PairConfirm
        val rig = rig(ConnectTarget.Pairing(ScriptedPairingHost.HOST_ID), mac)
        rig.controller.connect()
        advanceTimeBy(100)
        runCurrent()
        rig.controller.submitPairingCode(checkNotNull(mac.connections.single().host.shownCode))
        advanceTimeBy(130_000)
        runCurrent()

        val reason = failure(rig) as SessionFailure.ConnectionFailed
        assertEquals("The host stopped answering while waiting for the Mac to approve the pairing", reason.cause)
    }

    private fun failure(rig: ControllerRig): SessionFailure = (rig.controller.state.value.phase as SessionPhase.Failed).reason

    private fun TestScope.rig(
        target: ConnectTarget,
        mac: ScriptedMac = ScriptedMac(),
        nobodyDiscovered: Boolean = false,
        pins: FakePinStore = FakePinStore(mapOf(ScriptedPairingHost.HOST_ID to ScriptedPairingHost.HOST_KEY)),
    ) = ControllerRig(backgroundScope, testScheduler, target, mac, pins, nobodyDiscovered = nobodyDiscovered)
}
