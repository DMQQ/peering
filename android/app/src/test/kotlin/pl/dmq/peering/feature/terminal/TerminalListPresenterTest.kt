package pl.dmq.peering.feature.terminal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.terminal.TerminalSessions
import pl.dmq.peering.session.terminal.TerminalTab
import pl.dmq.peering.session.terminal.TerminalsState
import pl.dmq.peering.session.terminal.screen.ScreenSnapshot
import pl.dmq.peering.session.terminal.screen.StyledLine
import pl.dmq.peering.session.terminal.screen.StyledRun
import pl.dmq.peering.wire.TerminalAttentionKind
import pl.dmq.peering.wire.TerminalEvent
import pl.dmq.peering.wire.TerminalRequest
import pl.dmq.peering.wire.TerminalSessionInfo

class TerminalListPresenterTest {
    private val sent = mutableListOf<TerminalRequest>()
    private val sessions = TerminalSessions(send = { sent += it })
    private val presenter = TerminalListPresenter(sessions, AgentLaunchHistory(FakeKeyValueStore()))

    private fun info(id: String, name: String = id) = TerminalSessionInfo(id, name, true, null, null)

    private fun list(vararg ids: String) = sessions.onEvent(TerminalEvent.Snapshot(ids.map { info(it) }))

    private fun tab(id: String, running: Boolean = true, failure: String? = null, attention: TerminalAttentionKind? = null) =
        TerminalTab(id, id, running, 80, 24, failure = failure, attention = attention)

    private fun snapshot(rows: Int, vararg lines: String) =
        ScreenSnapshot(lines.map { StyledLine(listOf(StyledRun(it))) }, 0, 0, 80, rows, false)

    @Test
    fun aCardIsMarkedByWhatTheShellIsDoing() {
        val state = TerminalsState(
            tabs = listOf(
                tab("run"),
                tab("pass", attention = TerminalAttentionKind.PASSWORD),
                tab("ask", attention = TerminalAttentionKind.CONFIRMATION),
                tab("bad", failure = "no shell", attention = TerminalAttentionKind.PASSWORD),
                tab("gone", running = false),
            ),
        )
        val cards = TerminalListPresenter.cards(state)
        assertEquals(
            listOf(
                TerminalCardState.RUNNING,
                TerminalCardState.PASSWORD,
                TerminalCardState.CONFIRMATION,
                TerminalCardState.FAILED,
                TerminalCardState.EXITED,
            ),
            cards.map { it.state },
        )
        assertTrue(cards[1].needsYou)
        assertFalse(cards[0].needsYou)
        assertFalse(cards[4].isRunning)
    }

    @Test
    fun theListIsThePageUntilACardIsOpened() {
        list("a", "b")
        assertFalse(presenter.inShell.value)
        presenter.open("b")
        assertTrue(presenter.inShell.value)
        assertEquals("b", sessions.state.value.selectedID)
        presenter.back()
        assertFalse(presenter.inShell.value)
    }

    @Test
    fun aNewShellIsPushedOnceItArrives() {
        list("a")
        presenter.create()
        assertEquals(TerminalRequest.Create, sent.last())
        presenter.onState(sessions.state.value)
        assertFalse(presenter.inShell.value)
        sessions.onEvent(TerminalEvent.Created(info("b", "zsh")))
        presenter.onState(sessions.state.value)
        assertTrue(presenter.inShell.value)
        assertEquals("b", sessions.state.value.selectedID)
    }

    @Test
    fun aShellNobodyAskedForDoesNotPushAnything() {
        list("a")
        sessions.onEvent(TerminalEvent.Created(info("b", "zsh")))
        presenter.onState(sessions.state.value)
        assertFalse(presenter.inShell.value)
    }

    @Test
    fun theShellPageClosesWhenTheLastShellEnds() {
        list("a")
        presenter.open("a")
        sessions.onEvent(TerminalEvent.Closed("a"))
        presenter.onState(sessions.state.value)
        assertFalse(presenter.inShell.value)
    }

    @Test
    fun endAndRenameGoToTheShellAndABlankNameIsIgnored() {
        presenter.end("a")
        presenter.rename("a", "  build  ")
        presenter.rename("a", "   ")
        assertEquals(listOf(TerminalRequest.Close("a"), TerminalRequest.Rename("a", "build")), sent)
    }

    @Test
    fun theCardPreviewIsTheLastFourNonBlankLinesOfTheVisibleScreen() {
        val screen = snapshot(6, "scrolled off", "one", "", "two", "three", "", "four", "five")
        assertEquals(listOf("two", "three", "four", "five"), TerminalListPresenter.previewLines(screen))
    }

    @Test
    fun aLongPreviewLineIsClipped() {
        val lines = TerminalListPresenter.previewLines(snapshot(1, "x".repeat(200)))
        assertEquals(90, lines.single().length)
    }
}
