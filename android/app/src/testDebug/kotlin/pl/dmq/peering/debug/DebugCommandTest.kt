package pl.dmq.peering.debug

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DebugCommandTest {
    @Test
    fun `a tab name is accepted and an unknown one is rejected`() {
        assertEquals(DebugCommand.Run("tab", "sessions"), DebugCommand.parse("tab", "sessions"))
        assertTrue(DebugCommand.parse("tab", "billing") is DebugCommand.Invalid)
        assertTrue(DebugCommand.parse("tab", null) is DebugCommand.Invalid)
    }

    @Test
    fun `dock page forms become a page action`() {
        assertEquals(DebugCommand.Run("dock-page", "2"), DebugCommand.parse("dock", "page 2"))
        assertEquals(DebugCommand.Run("dock-page", "3"), DebugCommand.parse("dock", "page:3"))
        assertEquals(DebugCommand.Run("dock", "expand"), DebugCommand.parse("dock", "expand"))
        assertTrue(DebugCommand.parse("dock", "page x") is DebugCommand.Invalid)
        assertTrue(DebugCommand.parse("dock", "page 500") is DebugCommand.Invalid)
    }

    @Test
    fun `connect needs trusted or a plain host id`() {
        assertEquals(DebugCommand.Run("connect", "trusted"), DebugCommand.parse("connect", "trusted"))
        assertTrue(DebugCommand.parse("connect", "a b; rm") is DebugCommand.Invalid)
        assertTrue(DebugCommand.parse("connect", null) is DebugCommand.Invalid)
    }

    @Test
    fun `files open defaults to the home folder`() {
        assertEquals(DebugCommand.Run("files-open", "~"), DebugCommand.parse("files-open", null))
        assertEquals(DebugCommand.Run("files-open", "/Users/x"), DebugCommand.parse("files-open", " /Users/x "))
    }

    @Test
    fun `commands that act on the computer beyond the harness are unknown`() {
        listOf("key", "type", "click", "terminal-start", "agent-start", "delete", "files-delete").forEach {
            assertTrue(it, DebugCommand.parse(it, "x") is DebugCommand.Invalid)
        }
    }

    @Test
    fun `clipboard send is capped`() {
        assertEquals(DebugCommand.Run("clipboard-send", "marker"), DebugCommand.parse("clipboard-send", "marker"))
        assertTrue(DebugCommand.parse("clipboard-send", "x".repeat(501)) is DebugCommand.Invalid)
    }

    @Test
    fun `dump and a missing command`() {
        assertEquals(DebugCommand.Dump, DebugCommand.parse("dump", null))
        assertTrue(DebugCommand.parse(null, null) is DebugCommand.Invalid)
    }
}
