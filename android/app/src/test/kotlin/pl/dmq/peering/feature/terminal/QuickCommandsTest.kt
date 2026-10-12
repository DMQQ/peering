package pl.dmq.peering.feature.terminal

import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.session.ports.KeyValueStore

class QuickCommandsTest {
    private class MemoryStore : KeyValueStore {
        val values = mutableMapOf<String, String>()
        override fun read(key: String) = values[key]
        override fun write(key: String, value: String) {
            values[key] = value
        }
    }

    @Test
    fun displayTitleFallsBackToTheFirstWord() {
        assertEquals("docker", QuickCommand("1", "", "docker ps -a").displayTitle)
        assertEquals("Logs", QuickCommand("1", " Logs ", "tail -f x").displayTitle)
    }

    @Test
    fun codecKeepsTabsNewlinesAndBackslashes() {
        val commands = listOf(QuickCommand("a", "t\tab", "echo \\n\nx"), QuickCommand("b", "", "ls"))
        assertEquals(commands, QuickCommandCodec.decode(QuickCommandCodec.encode(commands)))
    }

    @Test
    fun savingReplacesTheSameIdAndPersists() {
        val store = MemoryStore()
        val commands = QuickCommands(store)
        commands.save(QuickCommand("a", "", "ls"))
        commands.save(QuickCommand("b", "", "pwd"))
        commands.save(QuickCommand("a", "List", "ls -l"))
        assertEquals(listOf("ls -l", "pwd"), QuickCommands(store).all.value.map { it.command })
    }

    @Test
    fun deletingRemovesOnlyThatCommand() {
        val commands = QuickCommands(MemoryStore())
        val first = QuickCommand("a", "", "ls")
        commands.save(first)
        commands.save(QuickCommand("b", "", "pwd"))
        commands.delete(first)
        assertEquals(listOf("b"), commands.all.value.map { it.id })
    }
}
