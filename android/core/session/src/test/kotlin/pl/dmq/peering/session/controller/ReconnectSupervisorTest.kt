@file:OptIn(ExperimentalCoroutinesApi::class)

package pl.dmq.peering.session.controller

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.ports.Clock
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

class ReconnectSupervisorTest {
    private var nowSeconds = 0.0
    private val clock = object : Clock {
        override fun monotonicSeconds() = nowSeconds
        override fun unixSeconds() = 0L
    }

    @Test
    fun theWaitsFollowTheIphoneLadderAndStopAfterItsSixSteps() {
        val supervisor = ReconnectSupervisor(clock)

        val steps = generateSequence { supervisor.nextStep() }.toList()

        assertEquals(listOf(250.milliseconds, 1.seconds, 3.seconds, 5.seconds, 8.seconds, 10.seconds), steps)
        assertEquals(6, supervisor.attempt)
    }

    @Test
    fun aPictureRestartsTheLadderFromItsShortestStep() {
        val supervisor = ReconnectSupervisor(clock)
        supervisor.nextStep()
        supervisor.nextStep()

        supervisor.pictureArrived()

        assertEquals(0, supervisor.attempt)
        assertEquals(250.milliseconds, supervisor.nextStep())
    }

    @Test
    fun aNetworkChangeEndsAWaitThatIsAlreadyRunning() = runTest {
        val supervisor = ReconnectSupervisor(clock)
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

    @Test
    fun theWindowClosesTheLadderThirtySecondsAfterTheFirstDrop() {
        val supervisor = ReconnectSupervisor(clock)
        supervisor.nextStep()

        nowSeconds = 30.0

        assertNull(supervisor.nextStep())
    }

    @Test
    fun aPictureOpensAFreshWindow() {
        val supervisor = ReconnectSupervisor(clock)
        supervisor.nextStep()
        nowSeconds = 40.0

        supervisor.pictureArrived()

        assertEquals(250.milliseconds, supervisor.nextStep())
    }
}
