package pl.dmq.peering.ui.wiring

import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONException
import pl.dmq.peering.feature.agents.FolderRecentsStore

/** Folder recents kept in preferences, one JSON list per Mac. */
internal class PreferencesFolderRecents(private val preferences: SharedPreferences) : FolderRecentsStore {
    override fun load(hostID: String): List<String> {
        val stored = preferences.getString(keyFor(hostID), null) ?: return emptyList()
        return try {
            val array = JSONArray(stored)
            List(array.length()) { array.getString(it) }
        } catch (failure: JSONException) {
            emptyList()
        }
    }

    override fun save(hostID: String, paths: List<String>) {
        preferences.edit().putString(keyFor(hostID), JSONArray(paths).toString()).apply()
    }

    private fun keyFor(hostID: String): String = KEY_PREFIX + hostID

    private companion object {
        const val KEY_PREFIX = "folder_recents_"
    }
}
