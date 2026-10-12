@file:OptIn(ExperimentalCoroutinesApi::class)

package pl.dmq.peering.session.controller

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

class ReconnectSupervisorTest {
    @Test
    fun theWaitsFollowTheLadderAndStopAfterItsFiveSteps() {
        val supervisor = ReconnectSupervisor()

        val steps = generateSequence { supervisor.nextStep() }.toList()

        assertEquals(listOf(500.milliseconds, 1.seconds, 2.seconds, 5.seconds, 5.seconds), steps)
        assertEquals(5, supervisor.attempt)
    }

    @Test
    fun aPictureRestartsTheLadderFromItsShortestStep() {
        val supervisor = ReconnectSupervisor()
        supervisor.nextStep()
        supervisor.nextStep()

        supervisor.pictureArrived()

        assertEquals(0, supervisor.attempt)
        assertEquals(500.milliseconds, supervisor.nextStep())
    }

    @Test
    fun aNetworkChangeEndsAWaitThatIsAlreadyRunning() = runTest {
        val supervisor = ReconnectSupervisor()
        var finished = false
        backgroundScope.launch {
            supervisor.waitFor(10.seconds)
            finished = true
        }
        runCurrent()
        assertFalse(finished)

        supervisor.networkChanged()
        runCurrent()

        assertTrue(finished)
        assertEquals(0L, testScheduler.currentTime)
    }
}
