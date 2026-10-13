package pl.dmq.peering.ui.wiring

import android.content.SharedPreferences
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import pl.dmq.peering.feature.settings.SettingsStore
import pl.dmq.peering.feature.settings.StreamQuality

internal class PreferencesSettingsStore(private val preferences: SharedPreferences) : SettingsStore {
    private val quality = MutableStateFlow(storedStreamQuality(preferences.getString(KEY_STREAM_QUALITY, null)))

    override fun streamQuality(): Flow<StreamQuality> = quality.asStateFlow()

    override fun currentStreamQuality(): StreamQuality = quality.value

    override fun saveStreamQuality(quality: StreamQuality): Boolean {
        val saved = preferences.edit().putString(KEY_STREAM_QUALITY, quality.stored()).commit()
        if (saved) this.quality.value = quality
        return saved
    }

    private companion object {
        const val KEY_STREAM_QUALITY = "stream_quality"
    }
}
