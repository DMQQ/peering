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
import pl.dmq.peering.session.flows.ScriptedPairingHost
import pl.dmq.peering.wire.MouseButton
import pl.dmq.peering.wire.MouseDown
import pl.dmq.peering.wire.MouseMove
import pl.dmq.peering.wire.MouseUp
import pl.dmq.peering.wire.NormalizedPoint
import pl.dmq.peering.wire.RemoteCommand
import pl.dmq.peering.wire.SetStreamQuality
import pl.dmq.peering.wire.SetVideoEnabled

class CommandSendingTest {
    @Test
    fun aCommandOfferedBeforeTheSessionIsReadyIsRefusedAndNeverSent() = runTest {
        val rig = lanRig(ScriptedMac())

        rig.controller.connect()
        assertFalse(rig.controller.send(MouseMove(NormalizedPoint(0.1, 0.1))))
        settle()

        assertTrue(rig.mac.connections.single().phoneFrames.commands().none { it is MouseMove })
    }

    @Test
    fun mouseMovesCoalesceWhileEveryButtonEventIsSentInOrder() = runTest {
        val rig = lanRig(ScriptedMac())
        rig.controller.connect()
        settle()

        rig.controller.send(MouseMove(NormalizedPoint(0.1, 0.1)))
        rig.controller.send(MouseMove(NormalizedPoint(0.2, 0.2)))
        rig.controller.send(MouseDown(MouseButton.LEFT))
        rig.controller.send(MouseMove(NormalizedPoint(0.3, 0.3)))
        rig.controller.send(MouseUp(MouseButton.LEFT))
        settle()

        assertEquals(
            listOf<RemoteCommand>(
                MouseMove(NormalizedPoint(0.2, 0.2)),
                MouseDown(MouseButton.LEFT),
                MouseMove(NormalizedPoint(0.3, 0.3)),
                MouseUp(MouseButton.LEFT),
            ),
            rig.mac.connections.single().phoneFrames.commands().filterNot { it is SetStreamQuality },
        )
    }

    @Test
    fun aCommandNeedingACapabilityTheHostDidNotDeclareIsRefused() = runTest {
        val rig = lanRig(ScriptedMac())
        rig.controller.connect()
        settle()

        assertFalse(rig.controller.setPictureEnabled(false))
        settle()

        assertTrue(rig.mac.connections.single().phoneFrames.commands().none { it is SetVideoEnabled })
        assertEquals(PictureState.Connecting, rig.controller.state.value.picture)
    }

    @Test
    fun aHostThatDeclaresVideoPauseAcceptsThePauseAndShowsThePictureAsPaused() = runTest {
        val rig = lanRig(ScriptedMac(declare = { it.copy(supportsVideoPause = true) }))
        rig.controller.connect()
        settle()

        assertTrue(rig.controller.setPictureEnabled(false))
        settle()

        assertEquals(listOf<RemoteCommand>(SetVideoEnabled(false)), rig.mac.connections.single().phoneFrames.commands().filterIsInstance<SetVideoEnabled>())
        assertEquals(PictureState.Paused, rig.controller.state.value.picture)
    }

    private fun TestScope.lanRig(mac: ScriptedMac): ControllerRig = ControllerRig(
        backgroundScope,
        testScheduler,
        ConnectTarget.Lan(ControllerRig.LAN_ADDRESS, ScriptedPairingHost.HOST_ID),
        mac,
    )

    private suspend fun TestScope.settle() {
        advanceTimeBy(100)
        runCurrent()
    }
}
