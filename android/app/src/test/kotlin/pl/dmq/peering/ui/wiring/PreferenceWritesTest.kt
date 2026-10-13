package pl.dmq.peering.ui.wiring

import java.util.concurrent.Executor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PreferenceWritesTest {
    private class Queue : Executor {
        val tasks = mutableListOf<Runnable>()

        override fun execute(command: Runnable) {
            tasks += command
        }

        fun runAll() = tasks.toList().also { tasks.clear() }.forEach { it.run() }
    }

    @Test
    fun savedValueIsReadableAtOnceAndOnDiskAfterTheWriterRuns() {
        val preferences = FakePreferences()
        val queue = Queue()

        PreferenceWrites(queue).save(preferences) { putBoolean("lock", true) }

        assertTrue(preferences.getBoolean("lock", false))
        assertFalse(preferences.disk.containsKey("lock"))
        queue.runAll()
        assertEquals(true, preferences.disk["lock"])
    }

    @Test
    fun laterValueIsBuiltOnTheWriterNotTheCaller() {
        val preferences = FakePreferences()
        val queue = Queue()
        var built = false

        PreferenceWrites(queue).saveTextLater(preferences, "history") {
            built = true
            "json"
        }

        assertFalse(built)
        queue.runAll()
        assertTrue(built)
        assertEquals("json", preferences.disk["history"])
    }

    @Test
    fun storesTakeTheWriterTheyAreGivenSoATestCanRunItDirectly() {
        val preferences = FakePreferences()
        val writes = PreferenceWrites(DirectExecutor)

        PreferencesKeyValueStore(preferences, writes).write("note", "hello")
        AppLock(preferences, writes).setEnabled(true)

        assertEquals("hello", preferences.disk["note"])
        assertEquals(true, preferences.disk["require_device_unlock"])
    }
}
