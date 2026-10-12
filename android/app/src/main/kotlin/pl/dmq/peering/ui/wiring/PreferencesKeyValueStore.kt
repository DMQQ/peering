package pl.dmq.peering.ui.wiring

import android.content.SharedPreferences
import pl.dmq.peering.session.ports.KeyValueStore

/** [KeyValueStore] over one SharedPreferences file. Writes are applied in the background, as the platform does for apply(). */
internal class PreferencesKeyValueStore(private val preferences: SharedPreferences) : KeyValueStore {
    override fun read(key: String): String? = preferences.getString(key, null)

    override fun write(key: String, value: String) {
        preferences.edit().putString(key, value).apply()
    }
}
