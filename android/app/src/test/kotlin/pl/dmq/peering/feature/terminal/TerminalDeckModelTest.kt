package pl.dmq.peering.feature.terminal

import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.session.ports.KeyValueStore
import pl.dmq.peering.session.terminal.TerminalTab
import pl.dmq.peering.wire.TerminalAttentionKind

class TerminalDeckModelTest {
    private fun tab(running: Boolean = true, failure: String? = null, attention: TerminalAttentionKind? = null) =
        TerminalTab("t", "zsh", running, 80, 24, failure = failure, attention = attention)

    @Test
    fun failureAndAttentionWinOverTheRest() {
        assertEquals(TerminalMark.FAILED, terminalMark(tab(failure = "no"), hasOutput = true))
        assertEquals(TerminalMark.PASSWORD, terminalMark(tab(attention = TerminalAttentionKind.PASSWORD), hasOutput = false))
        assertEquals(TerminalMark.QUESTION, terminalMark(tab(attention = TerminalAttentionKind.CONFIRMATION), hasOutput = true))
    }

    @Test
    fun aRunningShellWithoutOutputIsStarting() {
        assertEquals(TerminalMark.STARTING, terminalMark(tab(), hasOutput = false))
        assertEquals(TerminalMark.RUNNING, terminalMark(tab(), hasOutput = true))
        assertEquals(TerminalMark.STOPPED, terminalMark(tab(running = false), hasOutput = true))
    }

    @Test
    fun historyKeepsTheNewestFirstWithoutRepeats() {
        val history = emptyList<String>().withCommand("ls").withCommand("pwd").withCommand(" ls ").withCommand("")
        assertEquals(listOf("ls", "pwd"), history)
        assertEquals(2, listOf("a", "b", "c").withCommand("d", limit = 2).size)
    }

    @Test
    fun theDeckSendsTheSequencesAShellReads() {
        assertEquals("\u0003", TerminalKeySpecs.interrupt.bytes)
        assertEquals(listOf("\u001B[D", "\u001B[A", "\u001B[B", "\u001B[C"), TerminalKeySpecs.arrows.map { it.bytes })
        assertEquals(4, TerminalKeySpecs.groups.size)
        assertEquals("\u001B[3~", TerminalKeySpecs.groups[1].keys[1].bytes)
    }

    @Test
    fun textSizeFallsBackToDefaultForAnUnknownValue() {
        val values = mutableMapOf<String, String>()
        val store = object : KeyValueStore {
            override fun read(key: String) = values[key]
            override fun write(key: String, value: String) {
                values[key] = value
            }
        }
        val setting = TerminalTextSizeSetting(store)
        assertEquals(TerminalTextSize.REGULAR, setting.read())
        setting.write(TerminalTextSize.LARGE)
        assertEquals(TerminalTextSize.LARGE, setting.read())
        values.keys.toList().forEach { values[it] = "11" }
        assertEquals(TerminalTextSize.REGULAR, setting.read())
    }
}
