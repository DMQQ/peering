package pl.dmq.peering.ui.wiring

import android.content.SharedPreferences
import pl.dmq.peering.feature.onboarding.FirstRunStore

internal class PreferencesFirstRunStore(private val preferences: SharedPreferences) : FirstRunStore {
    override fun isComplete(): Boolean = preferences.getBoolean(KEY_COMPLETE, false)

    override fun markComplete() {
        preferences.edit().putBoolean(KEY_COMPLETE, true).apply()
    }

    private companion object {
        const val KEY_COMPLETE = "first_run_complete"
    }
}
