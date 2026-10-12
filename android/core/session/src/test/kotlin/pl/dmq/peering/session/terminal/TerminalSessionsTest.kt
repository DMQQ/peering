package pl.dmq.peering.session.terminal

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.terminal.screen.ScreenSnapshot
import pl.dmq.peering.wire.TerminalAttentionKind
import pl.dmq.peering.wire.TerminalEvent
import pl.dmq.peering.wire.TerminalRequest
import pl.dmq.peering.wire.TerminalSessionInfo
import pl.dmq.peering.wire.toBase64

class TerminalSessionsTest {
    private val sent = mutableListOf<TerminalRequest>()
    private val sessions = TerminalSessions(send = { sent += it })

    private fun info(id: String, name: String = id, running: Boolean = true, columns: Int? = null, rows: Int? = null) =
        TerminalSessionInfo(id, name, running, columns, rows)

    private fun output(id: String, text: String) = TerminalEvent.Output(id, text.toByteArray().toBase64())

    private fun open(vararg ids: String) = sessions.onEvent(TerminalEvent.Snapshot(ids.map { info(it) }))

    private fun text(id: String) = sessions.snapshot(id).lines.map { it.text }.dropLastWhile { it.isEmpty() }

    @Test
    fun attachAsksForTheListAndOpenAsksForAShell() {
        sessions.attach()
        sessions.open()
        assertEquals(listOf(TerminalRequest.ListTerminals, TerminalRequest.Create), sent)
    }

    @Test
    fun theListFillsTheTabsAndSelectsTheFirst() {
        assertFalse(sessions.state.value.loaded)
        open("a", "b")
        val state = sessions.state.value
        assertTrue(state.loaded)
        assertEquals(listOf("a", "b"), state.tabs.map { it.id })
        assertEquals("a", state.selectedID)
    }

    @Test
    fun aCreatedShellIsAddedAndSelected() {
        open("a")
        sessions.onEvent(TerminalEvent.Created(info("b", "zsh")))
        assertEquals(listOf("a", "b"), sessions.state.value.tabs.map { it.id })
        assertEquals("b", sessions.state.value.selectedID)
    }

    @Test
    fun outputIsFedToTheTabsOwnScreen() {
        open("a", "b")
        sessions.onEvent(output("a", "hi\r\n"))
        sessions.onEvent(output("b", "there"))
        assertEquals(listOf("hi"), text("a"))
        assertEquals(listOf("there"), text("b"))
        assertEquals(listOf("hi"), sessions.frames("a").value.lines.map { it.text }.dropLastWhile { it.isEmpty() })
    }

    @Test
    fun outputLeavesTheTabsAloneWhenNothingAboutThemChanged() {
        open("a")
        val before = sessions.state.value
        sessions.onEvent(output("a", "hi"))
        assertSame(before, sessions.state.value)
    }

    @Test
    fun outputForAnUnknownShellIsIgnored() {
        open("a")
        sessions.onEvent(output("ghost", "boo"))
        assertEquals(ScreenSnapshot.EMPTY, sessions.frames("ghost").value)
    }

    @Test
    fun inputGoesOutAsBase64Bytes() {
        sessions.input("a", "ls\r")
        sessions.input("a", ByteArray(0))
        val request = sent.single() as TerminalRequest.Input
        assertEquals("a", request.sessionID)
        assertArrayEquals("ls\r".toByteArray(), request.dataBytes)
    }

    @Test
    fun resizeSendsTheShapeAndRowsOnlyGrow() {
        sessions.onEvent(TerminalEvent.Snapshot(listOf(info("a", columns = 80, rows = 24))))
        sessions.resize("a", 100, 30)
        sessions.resize("a", 100, 12)
        assertEquals(
            listOf(TerminalRequest.Resize("a", 100, 30), TerminalRequest.Resize("a", 100, 30)),
            sent,
        )
        assertEquals(30, sessions.state.value.tabs.single().rows)
        assertEquals(100, sessions.state.value.tabs.single().columns)
    }

    @Test
    fun resizeOfAnUnknownShellSendsNothing() {
        sessions.resize("ghost", 80, 24)
        assertTrue(sent.isEmpty())
    }

    @Test
    fun closeAsksTheComputerAndTheTabGoesWhenItConfirms() {
        open("a", "b")
        sessions.select("b")
        sessions.close("b")
        assertEquals(listOf<TerminalRequest>(TerminalRequest.Close("b")), sent)
        assertEquals(2, sessions.state.value.tabs.size)
        sessions.onEvent(TerminalEvent.Closed("b"))
        assertEquals(listOf("a"), sessions.state.value.tabs.map { it.id })
        assertEquals("a", sessions.state.value.selectedID)
    }

    @Test
    fun exitKeepsTheTabAndRecordsTheStatus() {
        open("a")
        sessions.onEvent(TerminalEvent.Exited("a", 3))
        val tab = sessions.state.value.tabs.single()
        assertFalse(tab.isRunning)
        assertEquals(3, tab.exitStatus)
    }

    @Test
    fun aFailureForOneShellMarksThatTab() {
        open("a", "b")
        sessions.onEvent(TerminalEvent.Failed("b", "no pty"))
        assertNull(sessions.state.value.tabs[0].failure)
        assertEquals("no pty", sessions.state.value.tabs[1].failure)
        sessions.onEvent(output("b", "x"))
        assertNull(sessions.state.value.tabs[1].failure)
    }

    @Test
    fun aFailureWithNoShellIsHeldUntilDismissed() {
        sessions.onEvent(TerminalEvent.Failed(null, "could not start a shell"))
        assertEquals("could not start a shell", sessions.state.value.failure)
        sessions.dismissFailure()
        assertNull(sessions.state.value.failure)
    }

    @Test
    fun attentionSelectsTheTabAndOutputClearsIt() {
        open("a", "b")
        sessions.onEvent(TerminalEvent.Attention("b", TerminalAttentionKind.PASSWORD, "Password:"))
        assertEquals("b", sessions.state.value.selectedID)
        assertEquals(TerminalAttentionKind.PASSWORD, sessions.state.value.selected?.attention)
        sessions.onEvent(output("b", "x"))
        assertNull(sessions.state.value.selected?.attention)
    }

    @Test
    fun aReconnectListingRestartsEachScreenAtItsShapeForTheReplay() {
        open("a")
        sessions.resize("a", 100, 30)
        sessions.onEvent(output("a", "old"))
        sessions.onEvent(TerminalEvent.Snapshot(listOf(info("a"), info("c"))))
        assertEquals(emptyList<String>(), text("a"))
        assertEquals(100, sessions.state.value.tabs[0].columns)
        sessions.onEvent(output("a", "replayed"))
        assertEquals(listOf("replayed"), text("a"))
        assertEquals(listOf("a", "c"), sessions.state.value.tabs.map { it.id })
    }

    @Test
    fun aReconnectListingDropsShellsTheComputerNoLongerHas() {
        open("a", "b")
        sessions.select("b")
        sessions.onEvent(TerminalEvent.Snapshot(listOf(info("a"))))
        assertEquals("a", sessions.state.value.selectedID)
        assertEquals(emptyList<String>(), text("b"))
    }

    @Test
    fun renameUpdatesTheTabName() {
        open("a")
        sessions.rename("a", "build")
        assertEquals(TerminalRequest.Rename("a", "build"), sent.single())
        sessions.onEvent(TerminalEvent.Renamed(info("a", "build")))
        assertEquals("build", sessions.state.value.tabs.single().name)
    }
}
