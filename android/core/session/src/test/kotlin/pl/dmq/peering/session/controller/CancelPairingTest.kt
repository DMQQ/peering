@file:OptIn(ExperimentalCoroutinesApi::class)

package pl.dmq.peering.session.controller

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.flows.ScriptedPairingHost
import pl.dmq.peering.session.testing.FakePinStore
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.PairConfirm
import pl.dmq.peering.wire.WireJson

class CancelPairingTest {
    @Test
    fun cancellingWhileTheCodeIsAwaitedDeclinesToTheHostClosesAndReturnsToIdle() = runTest {
        val pins = FakePinStore()
        val rig = pairingRig(pins)
        rig.controller.connect()
        settle()
        assertTrue(rig.controller.state.value.phase is SessionPhase.EnteringPairingCode)

        rig.controller.cancelPairing()
        settle()

        val connection = rig.mac.connections.single()
        assertEquals(SessionPhase.Idle, rig.controller.state.value.phase)
        assertTrue(connection.closed)
        val answers = connection.phoneFrames.filter { it.kind == MessageKind.PairConfirm }
            .map { WireJson.decodeFromString(PairConfirm.serializer(), it.payload.decodeToString()).accepted }
        assertEquals(listOf(false), answers)
        assertNull(pins.pin(ScriptedPairingHost.HOST_ID))
    }

    @Test
    fun cancellingBeforeAnythingIsHeardClosesWithoutTellingTheHost() = runTest {
        val rig = pairingRig(FakePinStore())
        rig.mac.silentOn = MessageKind.ClientHello
        rig.controller.connect()
        settle()

        rig.controller.cancelPairing()
        settle()

        val connection = rig.mac.connections.single()
        assertEquals(SessionPhase.Idle, rig.controller.state.value.phase)
        assertTrue(connection.closed)
        assertTrue(connection.phoneFrames.none { it.kind == MessageKind.PairConfirm })
    }

    @Test
    fun cancellingAReadySessionLeavesItRunning() = runTest {
        val rig = ControllerRig(backgroundScope, testScheduler, ConnectTarget.Lan(ControllerRig.LAN_ADDRESS, ScriptedPairingHost.HOST_ID))
        rig.controller.connect()
        settle()

        rig.controller.cancelPairing()
        settle()

        assertTrue(rig.controller.state.value.phase is SessionPhase.Ready)
        assertTrue(!rig.mac.connections.single().closed)
        rig.controller.disconnect()
        settle()
    }

    @Test
    fun aPairingCanBeStartedAgainAfterItWasCancelled() = runTest {
        val rig = pairingRig(FakePinStore())
        rig.controller.connect()
        settle()
        rig.controller.cancelPairing()
        settle()

        rig.controller.connect()
        settle()

        assertEquals(2, rig.mac.connections.size)
        assertTrue(rig.controller.state.value.phase is SessionPhase.EnteringPairingCode)
        rig.controller.cancelPairing()
        settle()
    }

    private fun TestScope.pairingRig(pins: FakePinStore) = ControllerRig(
        backgroundScope,
        testScheduler,
        ConnectTarget.Pairing(ScriptedPairingHost.HOST_ID),
        ScriptedMac(alreadyPaired = false),
        pins,
    )
}
