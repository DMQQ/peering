package pl.dmq.peering.feature.remote

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import pl.dmq.peering.feature.settings.StreamQuality
import pl.dmq.peering.session.controller.QualityChoice
import pl.dmq.peering.wire.QualityTier

/** What the quality sheet reads and changes: the device's stored default, and the live session's ceiling and rate. */
interface QualityPort {
    val stored: Flow<StreamQuality>

    /** The highest tier the live session may stream at. */
    val ceiling: StateFlow<QualityTier>

    /** False when the default did not persist, so the sheet must not show the choice as made. */
    fun saveDefault(quality: StreamQuality): Boolean

    /** False when no session is running to apply the choice to. */
    fun apply(choice: QualityChoice): Boolean
}
