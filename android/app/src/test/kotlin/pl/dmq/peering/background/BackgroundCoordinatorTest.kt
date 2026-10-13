package pl.dmq.peering.background

import kotlinx.coroutines.flow.emptyFlow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.feature.settings.DevicePrefs
import pl.dmq.peering.session.controller.SessionPhase
import pl.dmq.peering.session.history.SessionRecord
import pl.dmq.peering.session.notices.KeepAliveStatus
import pl.dmq.peering.session.notices.Notice
import pl.dmq.peering.session.terminal.TerminalTab
import pl.dmq.peering.session.terminal.TerminalsState
import pl.dmq.peering.wire.TerminalAttentionKind

class BackgroundCoordinatorTest {
    private class FakeService(var accepts: Boolean = true) : KeepAliveHost {
        val calls = mutableListOf<String>()

        override fun run(status: KeepAliveStatus, hostName: String?, hostId: String?): Boolean {
            calls += "run $status $hostName"
            return accepts
        }

        override fun stop() {
            calls += "stop"
        }
    }

    private class FakeSink : NoticeSink {
        val posted = mutableListOf<Notice>()
        val retracted = mutableListOf<Set<String>>()

        override fun post(notice: Notice) {
            posted += notice
        }

        override fun retract(keys: Set<String>) {
            retracted += keys
        }
    }

    private val service = FakeService()
    private val sink = FakeSink()
    private val started = mutableListOf<Boolean>()
    private val coordinator = BackgroundCoordinator(emptyFlow(), emptyFlow(), emptyFlow(), service, sink) { started += it }

    private val prefs = DevicePrefs(deviceName = "Phone")
    private val ready = SessionPhase.Ready("Studio Mac", emptySet(), SessionRecord.Path.LAN)
    private val waiting = TerminalsState(tabs = listOf(TerminalTab("t1", "prod", true, 80, 24, attention = TerminalAttentionKind.PASSWORD)))

    private fun session(phase: SessionPhase = ready, terminals: TerminalsState? = null) = LiveSession(phase, "host1", null, terminals)

    @Test
    fun theServiceStartsWithTheSessionOnceAndStopsWhenItEnds() {
        coordinator.apply(session(SessionPhase.Connecting(SessionRecord.Path.LAN)), prefs, away = false)
        coordinator.apply(session(), prefs, away = false)
        coordinator.apply(session(), prefs, away = true)
        coordinator.apply(null, prefs, away = true)

        assertEquals(listOf("run Connecting null", "run Connected Studio Mac", "stop"), service.calls)
    }

    @Test
    fun theSettingKeepsTheServiceOff() {
        coordinator.apply(session(), prefs.copy(keepsSessionInBackground = false), away = false)
        assertTrue(service.calls.isEmpty())
    }

    @Test
    fun aRefusedStartIsRetriedWhenTheAppIsBackOnScreen() {
        service.accepts = false
        coordinator.apply(session(), prefs, away = true)
        coordinator.apply(session(), prefs, away = true)
        assertEquals(1, service.calls.size)

        service.accepts = true
        coordinator.apply(session(), prefs, away = false)
        assertEquals(2, service.calls.size)
    }

    @Test
    fun noticesArePostedOnlyWhileAwayAndRetractedOnReturn() {
        coordinator.apply(session(terminals = waiting), prefs, away = false)
        assertTrue(sink.posted.isEmpty())

        coordinator.apply(session(terminals = waiting), prefs, away = true)
        assertEquals(listOf("terminal:t1"), sink.posted.map { it.key })
        assertEquals("Studio Mac", sink.posted.single().hostName)

        coordinator.apply(session(terminals = waiting), prefs, away = false)
        assertEquals(listOf(setOf("terminal:t1")), sink.retracted)
    }

    @Test
    fun theNotificationsSettingSilencesNotices() {
        coordinator.apply(session(terminals = waiting), prefs.copy(notifies = false), away = true)
        assertTrue(sink.posted.isEmpty())
    }

    @Test
    fun theFirstSessionIsReportedOncePerSession() {
        coordinator.apply(session(), prefs, away = false)
        coordinator.apply(session(), prefs, away = false)
        coordinator.apply(null, prefs, away = false)
        coordinator.apply(session(), prefs.copy(notifies = false), away = false)
        assertEquals(listOf(true, false), started)
    }
}
