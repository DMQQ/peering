package pl.dmq.peering.feature.terminal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.feature.agents.FolderRecents
import pl.dmq.peering.feature.agents.InMemoryFolderRecentsStore
import pl.dmq.peering.session.terminal.TerminalSessions
import pl.dmq.peering.wire.TerminalEvent
import pl.dmq.peering.wire.TerminalRequest
import pl.dmq.peering.wire.TerminalSessionInfo

class TerminalFolderTest {
    private val sent = mutableListOf<TerminalRequest>()
    private val sessions = TerminalSessions(send = { sent += it })
    private val recents = FolderRecents(InMemoryFolderRecentsStore(), "host")

    private fun presenter(canChooseFolder: Boolean) =
        TerminalListPresenter(sessions, AgentLaunchHistory(FakeKeyValueStore()), canChooseFolder = canChooseFolder, recents = recents)

    private fun shellArrives(presenter: TerminalListPresenter) {
        sessions.onEvent(TerminalEvent.Created(TerminalSessionInfo("a", "zsh", true, null, null)))
        presenter.onState(sessions.state.value)
    }

    private fun typed() = sent.filterIsInstance<TerminalRequest.Input>().map { String(it.dataBytes) }

    @Test
    fun quotingKeepsEmbeddedQuotesInsideOneWord() {
        assertEquals("'/Users/me/it'\\''s'", ShellPath.quoted("/Users/me/it's"))
        assertEquals("cd -- '/tmp/a b'\r", ShellPath.changeDirectory("/tmp/a b"))
    }

    @Test
    fun newTerminalAsksForAFolderWhenTheComputerCanBrowse() {
        val presenter = presenter(canChooseFolder = true)
        presenter.beginNewTerminal()
        assertTrue(presenter.choosingFolder.value)
        assertFalse(sent.contains(TerminalRequest.Create))
        presenter.cancelFolder()
        assertFalse(presenter.choosingFolder.value)
    }

    @Test
    fun newTerminalOpensAtOnceWhenTheComputerCannotBrowse() {
        val presenter = presenter(canChooseFolder = false)
        presenter.beginNewTerminal()
        assertFalse(presenter.choosingFolder.value)
        assertTrue(sent.contains(TerminalRequest.Create))
    }

    @Test
    fun theChosenFolderIsSentAsTheFirstLineAndRemembered() {
        val presenter = presenter(canChooseFolder = true)
        presenter.beginNewTerminal()
        presenter.startIn("/Users/me/work")
        assertFalse(presenter.choosingFolder.value)
        assertTrue(sent.contains(TerminalRequest.Create))
        shellArrives(presenter)
        assertEquals(listOf("cd -- '/Users/me/work'\r"), typed())
        assertEquals(listOf("/Users/me/work"), recents.paths.value)
    }

    @Test
    fun aShellWithoutAFolderGetsNoCd() {
        val presenter = presenter(canChooseFolder = true)
        presenter.create()
        shellArrives(presenter)
        assertEquals(emptyList<String>(), typed())
    }
}
