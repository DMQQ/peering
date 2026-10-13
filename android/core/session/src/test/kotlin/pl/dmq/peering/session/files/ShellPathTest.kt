package pl.dmq.peering.session.files

import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.session.terminal.TerminalSessions
import pl.dmq.peering.wire.TerminalEvent
import pl.dmq.peering.wire.TerminalRequest
import pl.dmq.peering.wire.TerminalSessionInfo

class ShellPathTest {
    @Test
    fun `a path with a space stays one argument and a quote cannot end the quoting`() {
        assertEquals("'/Users/me/My Documents/a.sh'", ShellPath.quoted("/Users/me/My Documents/a.sh"))
        assertEquals("'it'\\''s; rm -rf ~'", ShellPath.quoted("it's; rm -rf ~"))
    }

    @Test
    fun `running a file steps into its folder first`() {
        assertEquals("cd -- '/Users/me/app' && '/Users/me/app/run.sh'", ShellPath.runCommand("/Users/me/app/run.sh"))
        assertEquals("cd -- '/' && '/run.sh'", ShellPath.runCommand("/run.sh"))
        assertEquals("'run.sh'", ShellPath.runCommand("run.sh"))
    }

    @Test
    fun `a command to run in a new shell is typed once the shell exists and not before`() {
        val sent = mutableListOf<TerminalRequest>()
        val sessions = TerminalSessions(send = { sent += it })

        sessions.runInNewTerminal("ls -l")
        assertEquals(listOf<TerminalRequest>(TerminalRequest.Create), sent)

        sessions.onEvent(TerminalEvent.Created(TerminalSessionInfo(id = "T1", name = "zsh", isRunning = true)))

        val typed = sent.filterIsInstance<TerminalRequest.Input>().single()
        assertEquals("T1", typed.sessionID)
        assertEquals("ls -l\r", String(java.util.Base64.getDecoder().decode(typed.data)))
    }

    @Test
    fun `a shell the person opens by hand gets nothing typed into it`() {
        val sent = mutableListOf<TerminalRequest>()
        val sessions = TerminalSessions(send = { sent += it })

        sessions.onEvent(TerminalEvent.Created(TerminalSessionInfo(id = "T1", name = "zsh", isRunning = true)))

        assertEquals(emptyList<TerminalRequest>(), sent)
    }
}
