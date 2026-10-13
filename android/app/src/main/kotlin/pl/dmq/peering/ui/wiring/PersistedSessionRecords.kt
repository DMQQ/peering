package pl.dmq.peering.ui.wiring

import android.content.SharedPreferences
import pl.dmq.peering.DebugLog
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.SerializationException
import pl.dmq.peering.feature.sessions.SessionRecords
import pl.dmq.peering.session.history.SessionHistory
import pl.dmq.peering.session.history.SessionRecord

/** The session history, kept across launches: [refresh] publishes what the sessions have recorded and stores it. */
internal class PersistedSessionRecords(
    val history: SessionHistory,
    private val preferences: SharedPreferences,
    private val writes: PreferenceWrites,
) : SessionRecords {
    private val current = MutableStateFlow(history.records)

    override val records: StateFlow<List<SessionRecord>> = current.asStateFlow()

    fun refresh() {
        val records = history.records
        current.value = records
        writes.saveTextLater(preferences, KEY) { SessionHistory.toJson(records) }
    }

    companion object {
        private const val KEY = "session_history"
        private const val TAG = "PeeringSession"

        /** A history that cannot be read starts again empty, which is logged: the records are only a convenience. */
        fun load(preferences: SharedPreferences, writes: PreferenceWrites): PersistedSessionRecords {
            val stored = preferences.getString(KEY, null)
            val history = if (stored == null) {
                SessionHistory()
            } else {
                try {
                    SessionHistory.fromJson(stored)
                } catch (failure: SerializationException) {
                    DebugLog.w(TAG, { "the stored session history could not be read, starting again" }, failure)
                    SessionHistory()
                }
            }
            return PersistedSessionRecords(history, preferences, writes)
        }
    }
}
