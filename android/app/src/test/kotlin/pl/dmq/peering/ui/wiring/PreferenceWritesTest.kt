package pl.dmq.peering.ui.wiring

import android.content.SharedPreferences
import java.util.concurrent.Executor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PreferenceWritesTest {
    private class FakePreferences : SharedPreferences {
        val memory = mutableMapOf<String, Any?>()
        val disk = mutableMapOf<String, Any?>()

        override fun getAll(): MutableMap<String, *> = memory
        override fun getString(key: String, defValue: String?): String? = memory[key] as? String ?: defValue
        override fun getStringSet(key: String, defValues: MutableSet<String>?): MutableSet<String>? = defValues
        override fun getInt(key: String, defValue: Int): Int = memory[key] as? Int ?: defValue
        override fun getLong(key: String, defValue: Long): Long = memory[key] as? Long ?: defValue
        override fun getFloat(key: String, defValue: Float): Float = memory[key] as? Float ?: defValue
        override fun getBoolean(key: String, defValue: Boolean): Boolean = memory[key] as? Boolean ?: defValue
        override fun contains(key: String): Boolean = key in memory
        override fun registerOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener) = Unit
        override fun unregisterOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener) = Unit

        override fun edit(): SharedPreferences.Editor = object : SharedPreferences.Editor {
            private val pending = mutableMapOf<String, Any?>()

            override fun putString(key: String, value: String?) = apply { pending[key] = value }
            override fun putStringSet(key: String, values: MutableSet<String>?) = apply { pending[key] = values }
            override fun putInt(key: String, value: Int) = apply { pending[key] = value }
            override fun putLong(key: String, value: Long) = apply { pending[key] = value }
            override fun putFloat(key: String, value: Float) = apply { pending[key] = value }
            override fun putBoolean(key: String, value: Boolean) = apply { pending[key] = value }
            override fun remove(key: String) = apply { pending[key] = null }
            override fun clear() = apply { memory.clear() }

            override fun commit(): Boolean {
                memory.putAll(pending)
                disk.clear()
                disk.putAll(memory)
                return true
            }

            override fun apply() {
                memory.putAll(pending)
            }
        }
    }

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
}
