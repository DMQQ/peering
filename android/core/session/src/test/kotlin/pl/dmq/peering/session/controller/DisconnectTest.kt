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
}
