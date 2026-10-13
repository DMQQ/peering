@file:OptIn(ExperimentalCoroutinesApi::class)

package pl.dmq.peering.session.controller

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.job
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.history.SessionRecord
import pl.dmq.peering.session.flows.ScriptedPairingHost
import kotlin.coroutines.coroutineContext

class DisconnectTest {
    @Test
    fun disconnectCancelsEveryChildJobAndClosesTheConnection() = runTest {
        val rig = ControllerRig(this, testScheduler, ConnectTarget.Lan(ControllerRig.LAN_ADDRESS, ScriptedPairingHost.HOST_ID))
        rig.controller.connect()
        advanceTimeBy(1_000)
        runCurrent()
        assertTrue(coroutineContext.job.children.any(Job::isActive))

        rig.controller.disconnect()
        runCurrent()

        assertEquals(SessionPhase.Ended, rig.controller.state.value.phase)
        assertTrue(rig.mac.connections.single().closed)
        assertTrue(coroutineContext.job.children.none(Job::isActive))
    }

    @Test
    fun aUserDisconnectIsNeverFollowedByAReconnectHoweverLongTheClockRuns() = runTest {
        val rig = ControllerRig(this, testScheduler, ConnectTarget.Lan(ControllerRig.LAN_ADDRESS, ScriptedPairingHost.HOST_ID))
        rig.controller.connect()
        advanceTimeBy(1_000)
        runCurrent()

        rig.controller.disconnect()
        advanceTimeBy(10 * 60 * 1_000L)
        runCurrent()

        assertEquals(SessionPhase.Ended, rig.controller.state.value.phase)
        assertEquals(1, rig.routes.count { it !is ControlRoute.Video })
        assertEquals(1, rig.mac.connections.size)
        assertTrue(rig.mac.connections.single().closed)
        assertEquals(SessionRecord.EndReason.USER_ENDED, rig.history.records.single().reason)
        assertEquals(1, rig.sink.stops)
        assertTrue(coroutineContext.job.children.none(Job::isActive))
    }

    @Test
    fun aDisconnectWhileTheHostIsStillBeingDialledEndsTheSessionWithoutALink() = runTest {
        val rig = ControllerRig(this, testScheduler, ConnectTarget.Paired(ScriptedPairingHost.HOST_ID, null, null, relayAllowed = false), nobodyDiscovered = true)
        rig.controller.connect()
        advanceTimeBy(100)

        rig.controller.disconnect()
        advanceTimeBy(60_000)
        runCurrent()

        assertEquals(SessionPhase.Ended, rig.controller.state.value.phase)
        assertTrue(rig.routes.isEmpty())
    }

    @Test
    fun aSessionCanBeStartedAgainAfterADisconnect() = runTest {
        val rig = ControllerRig(this, testScheduler, ConnectTarget.Lan(ControllerRig.LAN_ADDRESS, ScriptedPairingHost.HOST_ID))
        rig.controller.connect()
        advanceTimeBy(1_000)
        runCurrent()
        rig.controller.disconnect()
        runCurrent()

        rig.controller.connect()
        advanceTimeBy(1_000)
        runCurrent()

        assertTrue(rig.controller.state.value.phase is SessionPhase.Ready)
        assertEquals(2, rig.mac.connections.size)
        rig.controller.disconnect()
        runCurrent()
    }
}
