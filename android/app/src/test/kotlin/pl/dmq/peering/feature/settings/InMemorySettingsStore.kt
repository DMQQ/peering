package pl.dmq.peering.feature.settings

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow

class InMemorySettingsStore(
    initial: StreamQuality = StreamQuality.Auto,
    private val saveSucceeds: Boolean = true,
) : SettingsStore {
    private val quality = MutableStateFlow(initial)
    val saved = mutableListOf<StreamQuality>()

    override fun streamQuality(): Flow<StreamQuality> = quality

    override fun saveStreamQuality(quality: StreamQuality): Boolean {
        saved += quality
        if (saveSucceeds) this.quality.value = quality
        return saveSucceeds
    }
}
