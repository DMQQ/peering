package pl.dmq.peering.ui.wiring

import android.content.SharedPreferences
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import pl.dmq.peering.DebugLog

/**
 * Preference writes that never block the main thread and are on disk before the next one starts. An `apply()` alone is
 * flushed by the framework in a place it may block (activity stop) and is lost if the process dies first.
 */
internal class PreferenceWrites(private val executor: Executor) {
    /** The value is readable at once; a background commit then makes sure it reached the disk. */
    fun save(preferences: SharedPreferences, edit: SharedPreferences.Editor.() -> Unit) {
        preferences.edit().apply(edit).apply()
        executor.execute { flush(preferences) }
    }

    /** For text that is costly to build: [text] runs on the writer, not on the caller. */
    fun saveTextLater(preferences: SharedPreferences, key: String, text: () -> String) {
        executor.execute {
            val built = text()
            commit(preferences) { putString(key, built) }
        }
    }

    private fun flush(preferences: SharedPreferences) {
        report(preferences.edit().commit())
    }

    private fun commit(preferences: SharedPreferences, edit: SharedPreferences.Editor.() -> Unit) {
        report(preferences.edit().apply(edit).commit())
    }

    private fun report(written: Boolean) {
        if (!written) DebugLog.w(TAG, { "a preference write did not reach the disk" })
    }

    companion object {
        private const val TAG = "PeeringPreferences"

        val shared = PreferenceWrites(Executors.newSingleThreadExecutor { task -> Thread(task, "peering-preferences").apply { isDaemon = true } })
    }
}
