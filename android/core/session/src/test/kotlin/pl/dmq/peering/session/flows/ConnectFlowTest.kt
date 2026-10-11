@file:OptIn(ExperimentalCoroutinesApi::class)

package pl.dmq.peering.session.flows

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestCoroutineScheduler
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.session.connection.ClientAction
import pl.dmq.peering.session.connection.ClientConfig
import pl.dmq.peering.session.connection.ClientStateMachine
import pl.dmq.peering.session.connection.LivenessMonitor
import pl.dmq.peering.session.ports.Clock
import pl.dmq.peering.session.testing.FakePinStore
import pl.dmq.peering.session.testing.FixedRandom
import pl.dmq.peering.wire.ErrorPayload
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.ReconnectLadder
import pl.dmq.peering.wire.ServerHello
import pl.dmq.peering.wire.WireJson
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

class ConnectFlowTest {
    @Test
    fun aLanConnectReachesReadyAndStaysUpWhileTheHostAnswers() = runTest {
        val driver = SessionDriver(testScheduler)
        driver.run(backgroundScope)
        runCurrent()
        assertEquals(listOf<DriverEvent>(DriverEvent.Connected(0)), driver.events)
        assertEquals(ScriptedPairingHost.HOST_ID, driver.readyHello?.serverID)

        advanceTimeBy(5_000)
        assertEquals(listOf<DriverEvent>(DriverEvent.Connected(0)), driver.events)
    }

    @Test
    fun aSilentHostTriggersTheLadderUntilItIsUsedUp() = runTest {
        val driver = SessionDriver(testScheduler)
        driver.run(backgroundScope)
        advanceTimeBy(2_500)
        driver.hostReachable = false
        advanceTimeBy(20_000)

        assertEquals(
            listOf<DriverEvent>(
                DriverEvent.Connected(0),
                DriverEvent.Silent(6_000),
                DriverEvent.Attempt(6_500),
                DriverEvent.Attempt(7_500),
                DriverEvent.Attempt(9_500),
                DriverEvent.Attempt(14_500),
                DriverEvent.Attempt(19_500),
                DriverEvent.Exhausted(19_500),
            ),
            driver.events,
        )
    }

    @Test
    fun aHostStoppedErrorEndsTheSessionWithoutReconnecting() = runTest {
        val driver = SessionDriver(testScheduler)
        driver.run(backgroundScope)
        advanceTimeBy(1_500)
        driver.onControlFrame(errorFrame(ErrorPayload.HOST_STOPPED_CODE))
        driver.hostReachable = false
        advanceTimeBy(60_000)

        assertEquals(listOf<DriverEvent>(DriverEvent.Connected(0), DriverEvent.Stopped(1_500)), driver.events)
    }

    @Test
    fun anErrorWithAnotherCodeLeavesTheSessionAlone() = runTest {
        val driver = SessionDriver(testScheduler)
        driver.run(backgroundScope)
        advanceTimeBy(1_500)
        driver.onControlFrame(errorFrame("busy"))
        advanceTimeBy(1_000)

        assertEquals(listOf<DriverEvent>(DriverEvent.Connected(0)), driver.events)
    }

    @Test
    fun aNetworkChangeRestartsTheLadderFromItsShortestStep() = runTest {
        val driver = SessionDriver(testScheduler)
        driver.run(backgroundScope)
        advanceTimeBy(2_500)
        driver.hostReachable = false
        advanceTimeBy(5_500)
        driver.hostReachable = true
        driver.networkChanged()
        advanceTimeBy(1_000)

        assertEquals(
            listOf<DriverEvent>(
                DriverEvent.Connected(0),
                DriverEvent.Silent(6_000),
                DriverEvent.Attempt(6_500),
                DriverEvent.Attempt(7_500),
                DriverEvent.Attempt(8_500),
                DriverEvent.Connected(8_500),
            ),
            driver.events,
        )
    }

    private fun errorFrame(code: String): Frame = Frame(
        MessageKind.Error,
        WireJson.encodeToString(ErrorPayload.serializer(), ErrorPayload(code, "message")).toByteArray(Charsets.UTF_8),
    )
}

private sealed interface DriverEvent {
    val atMillis: Long

    data class Connected(override val atMillis: Long) : DriverEvent

    data class Silent(override val atMillis: Long) : DriverEvent

    data class Attempt(override val atMillis: Long) : DriverEvent

    data class Stopped(override val atMillis: Long) : DriverEvent

    data class Exhausted(override val atMillis: Long) : DriverEvent
}

/**
 * One phone's session with one Mac: a handshake to Ready, then pings once a second until the host has been silent
 * past [SILENCE_LIMIT_SECONDS]. Each drop waits out the next [ReconnectLadder] step before dialling again. A
 * [networkChanged] resets the ladder and cuts the current wait short, so the next dial comes after the first step.
 */
private class SessionDriver(private val scheduler: TestCoroutineScheduler) {
    private val clock = SchedulerClock(scheduler)
    private val pins = FakePinStore(mapOf(ScriptedPairingHost.HOST_ID to ScriptedPairingHost.HOST_KEY))
    private val ladder = ReconnectLadder()
    private val networkChanges = Channel<Unit>(Channel.CONFLATED)
    private var liveness: LivenessMonitor? = null
    private var stopped = false

    /** Whether the Mac answers at all: it sets the outcome of every dial and of every ping. */
    var hostReachable = true

    var readyHello: ServerHello? = null
        private set

    val events = mutableListOf<DriverEvent>()

    fun run(scope: CoroutineScope) {
        scope.launch { session() }
    }

    fun networkChanged() {
        ladder.reset()
        networkChanges.trySend(Unit)
    }

    fun onControlFrame(frame: Frame) {
        if (frame.kind != MessageKind.Error) return
        val error = WireJson.decodeFromString(ErrorPayload.serializer(), frame.payload.decodeToString())
        if (error.code != ErrorPayload.HOST_STOPPED_CODE) return
        stopped = true
        events += DriverEvent.Stopped(now())
    }

    private suspend fun session() {
        var connected = openConnection()
        while (!stopped) {
            if (connected) {
                if (!pingUntilSilent()) return
                events += DriverEvent.Silent(now())
                connected = false
            } else {
                val step = ladder.next()
                if (step == null) {
                    events += DriverEvent.Exhausted(now())
                    return
                }
                if (interruptedWhileWaiting(step)) continue
                if (stopped) return
                events += DriverEvent.Attempt(now())
                connected = openConnection()
            }
        }
    }

    private fun openConnection(): Boolean {
        if (!hostReachable) return false
        val machine = ClientStateMachine(
            ClientConfig(CLIENT_ID, "Phone", ScriptedPairingHost.HOST_ID, ScriptedPairingHost.HOST_KEY),
            pins,
            FixedRandom(1),
        )
        val link = PairingLink(machine, ScriptedPairingHost(alreadyPaired = true))
        link.start()
        val ready = link.actions.filterIsInstance<ClientAction.Ready>().singleOrNull() ?: return false
        readyHello = ready.hello
        liveness = LivenessMonitor(clock)
        events += DriverEvent.Connected(now())
        return true
    }

    /** False when the host ended the session while the connection was up. */
    private suspend fun pingUntilSilent(): Boolean {
        val monitor = checkNotNull(liveness)
        while (!stopped) {
            delay(PING_INTERVAL)
            val ping = monitor.nextPing()
            if (hostReachable) monitor.onPong(Frame(MessageKind.Pong, ping.payload))
            if (monitor.isSilent(clock.monotonicSeconds(), SILENCE_LIMIT_SECONDS)) return true
        }
        return false
    }

    /** True when a network change ended the wait early. A change made while connected is drained, not kept. */
    private suspend fun interruptedWhileWaiting(step: Duration): Boolean {
        networkChanges.tryReceive()
        return withTimeoutOrNull(step) { networkChanges.receive() } != null
    }

    private fun now(): Long = scheduler.currentTime

    private companion object {
        const val CLIENT_ID = "11111111-2222-4333-8444-555555555555"
        val PING_INTERVAL: Duration = LivenessMonitor.PING_INTERVAL_SECONDS.seconds
        const val SILENCE_LIMIT_SECONDS = 3.0
    }
}

/** Reads virtual milliseconds from the test scheduler, so silence and backoff follow the test's clock. */
private class SchedulerClock(private val scheduler: TestCoroutineScheduler) : Clock {
    override fun monotonicSeconds(): Double = scheduler.currentTime / MILLIS_PER_SECOND

    override fun unixSeconds(): Long = 0

    private companion object {
        const val MILLIS_PER_SECOND = 1000.0
    }
}
