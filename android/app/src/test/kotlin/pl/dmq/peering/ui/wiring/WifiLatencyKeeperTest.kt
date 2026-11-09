@file:OptIn(ExperimentalCoroutinesApi::class)

package pl.dmq.peering.ui.wiring

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.session.controller.SessionFailure
import pl.dmq.peering.session.controller.SessionPhase
import pl.dmq.peering.session.history.SessionRecord

class WifiLatencyKeeperTest {
    private val events = mutableListOf<String>()
    private val phases = MutableStateFlow<SessionPhase?>(null)
    private val onScreen = MutableStateFlow(true)
    private val connecting = SessionPhase.Connecting(SessionRecord.Path.LAN)

    private fun keeper() = WifiLatencyKeeper(phases, onScreen, acquire = { events += "acquire" }, release = { events += "release" })

    @Test
    fun theLockIsHeldFromTheFirstConnectAttemptAndLetGoWhenTheSessionEnds() = runTest {
        keeper().start(backgroundScope)
        runCurrent()
        phases.value = connecting
        runCurrent()
        phases.value = SessionPhase.Ended
        runCurrent()

        assertEquals(listOf("release", "acquire", "release"), events)
    }

    @Test
    fun movingBetweenLiveStatesDoesNotTouchTheLockAgain() = runTest {
        keeper().start(backgroundScope)
        phases.value = connecting
        runCurrent()
        phases.value = SessionPhase.Reconnecting(attempt = 1)
        runCurrent()
        phases.value = connecting
        runCurrent()

        assertEquals(listOf("acquire"), events)
    }

    @Test
    fun aFailedSessionLetsTheRadioSleepAgain() = runTest {
        keeper().start(backgroundScope)
        phases.value = connecting
        runCurrent()
        phases.value = SessionPhase.Failed(SessionFailure.ConnectionLost, canRetry = true)
        runCurrent()

        assertEquals(listOf("acquire", "release"), events)
    }

    @Test
    fun typingAPairingCodeDoesNotKeepTheRadioAwake() = runTest {
        keeper().start(backgroundScope)
        phases.value = SessionPhase.EnteringPairingCode(attempts = 0)
        runCurrent()

        assertEquals(listOf("release"), events)
    }

    @Test
    fun leavingTheAppLetsTheRadioSleepAndComingBackHoldsItAgain() = runTest {
        keeper().start(backgroundScope)
        phases.value = connecting
        runCurrent()
        onScreen.value = false
        runCurrent()
        onScreen.value = true
        runCurrent()

        assertEquals(listOf("acquire", "release", "acquire"), events)
    }

    @Test
    fun aSessionStartedWhileTheAppIsAwayDoesNotHoldTheLock() = runTest {
        onScreen.value = false
        keeper().start(backgroundScope)
        phases.value = connecting
        runCurrent()

        assertEquals(listOf("release"), events)
    }
}
