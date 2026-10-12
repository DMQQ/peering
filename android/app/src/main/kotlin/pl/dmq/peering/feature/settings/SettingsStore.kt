package pl.dmq.peering.feature.settings

import kotlinx.coroutines.flow.Flow

/** This device's preferences. */
interface SettingsStore {
    fun streamQuality(): Flow<StreamQuality>

    /** False when the value did not persist, so the screen must not show it as chosen. */
    fun saveStreamQuality(quality: StreamQuality): Boolean
}
