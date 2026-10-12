package pl.dmq.peering.ui.wiring

import android.content.SharedPreferences
import pl.dmq.peering.session.ports.KeyValueStore

/** [KeyValueStore] over one SharedPreferences file. Writes reach the disk on a background thread. */
internal class PreferencesKeyValueStore(private val preferences: SharedPreferences) : KeyValueStore {
    override fun read(key: String): String? = preferences.getString(key, null)

    override fun write(key: String, value: String) {
        PreferenceWrites.shared.save(preferences) { putString(key, value) }
    }
}
