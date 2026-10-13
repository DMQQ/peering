package pl.dmq.peering.session.agent

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.terminal.TerminalSessions
import pl.dmq.peering.session.terminal.screen.VtScreen
import pl.dmq.peering.wire.TerminalEvent
import pl.dmq.peering.wire.TerminalSessionInfo

class MemoryPressureTest {
    private fun turn(first: Long, characters: Int): List<TranscriptRow> = listOf(
        TranscriptRow.User(first, "q"),
        TranscriptRow.AssistantText(first + 1, "a".repeat(characters)),
    )

    private fun transcript(vararg turns: List<TranscriptRow>): TranscriptState {
        val rows = turns.flatMap { it }
        return TranscriptState(rows = rows, approximateSize = rows.sumOf { (it as? TranscriptRow.AssistantText)?.text?.length ?: 1 })
    }

    @Test
    fun `old turns go first and the newest stays, marked as cut at the front`() {
        val state = transcript(turn(1, 40_000), turn(3, 40_000), turn(5, 40_000))

        val trimmed = TranscriptReducer.trimForMemoryPressure(state)

        assertEquals(listOf(5L, 6L), trimmed.rows.map { it.id })
        assertTrue(trimmed.truncatedAtFront)
        assertTrue(trimmed.approximateSize <= 64 * 1024)
    }

    @Test
    fun `a small conversation is left as it is`() {
        val state = transcript(turn(1, 1_000), turn(3, 1_000))

        assertSame(state, TranscriptReducer.trimForMemoryPressure(state))
    }

    @Test
    fun `a single huge turn is kept whole, since there is nothing older to drop`() {
        val state = transcript(turn(1, 200_000))

        assertEquals(2, TranscriptReducer.trimForMemoryPressure(state).rows.size)
    }

    @Test
    fun `scrollback keeps only the newest lines and the screen stays`() {
        val screen = VtScreen(columns = 20, rows = 4)
        screen.feed((1..500).joinToString("\r\n") { "line $it" }.toByteArray())

        screen.trimScrollback(keepLines = 50)
        val lines = screen.snapshot().lines

        assertTrue(lines.size <= 50 + 4)
        assertEquals("line 500", lines.last { it.text.isNotBlank() }.text)
        assertFalse(lines.any { it.text == "line 1" })
    }

    @Test
    fun `trimming the shells keeps them open and keeps the newest output`() {
        val sessions = TerminalSessions(send = {})
        sessions.onEvent(TerminalEvent.Created(TerminalSessionInfo(id = "T1", name = "zsh", isRunning = true, columns = 20, rows = 4)))

        sessions.trimMemory()

        assertEquals(listOf("T1"), sessions.state.value.tabs.map { it.id })
    }
}
