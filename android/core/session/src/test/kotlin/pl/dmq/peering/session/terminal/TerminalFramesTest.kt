package pl.dmq.peering.session.terminal

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.wire.TerminalEvent
import pl.dmq.peering.wire.TerminalSessionInfo
import pl.dmq.peering.wire.toBase64

@OptIn(ExperimentalCoroutinesApi::class)
class TerminalFramesTest {
    private val scope = TestScope(StandardTestDispatcher())
    private val sessions = TerminalSessions(send = {}, scope = scope)

    private fun output(text: String) = TerminalEvent.Output("a", text.toByteArray().toBase64())

    private fun shown() = sessions.frames("a").value.lines.map { it.text }.dropLastWhile { it.isEmpty() }

    @Test
    fun aBurstOfOutputIsPublishedOnceAtTheNextFrame() {
        sessions.onEvent(TerminalEvent.Snapshot(listOf(TerminalSessionInfo("a", "a", true, null, null))))
        sessions.onEvent(output("one\r\n"))
        sessions.onEvent(output("two\r\n"))
        sessions.onEvent(output("three"))
        scope.runCurrent()
        assertEquals(emptyList<String>(), shown())
        scope.advanceTimeBy(20)
        assertEquals(listOf("one", "two", "three"), shown())
    }

    @Test
    fun outputAfterAFrameStartsTheNextOne() {
        sessions.onEvent(TerminalEvent.Snapshot(listOf(TerminalSessionInfo("a", "a", true, null, null))))
        sessions.onEvent(output("one"))
        scope.advanceTimeBy(20)
        sessions.onEvent(output("!"))
        scope.advanceTimeBy(20)
        assertEquals(listOf("one!"), shown())
    }
}
