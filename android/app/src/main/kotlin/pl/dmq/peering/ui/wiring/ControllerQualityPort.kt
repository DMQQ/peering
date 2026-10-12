package pl.dmq.peering.ui.wiring

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import pl.dmq.peering.feature.remote.QualityPort
import pl.dmq.peering.feature.settings.SettingsStore
import pl.dmq.peering.feature.settings.StreamQuality
import pl.dmq.peering.session.controller.QualityChoice
import pl.dmq.peering.session.controller.SessionController
import pl.dmq.peering.wire.QualityTier

/** The quality sheet over the live session and the stored default. */
internal class ControllerQualityPort(
    private val controller: SessionController,
    private val settings: SettingsStore,
    scope: CoroutineScope,
) : QualityPort {
    override val stored = settings.streamQuality()

    override val ceiling: StateFlow<QualityTier> = controller.state
        .map { it.qualityCeiling }
        .stateIn(scope, SharingStarted.Eagerly, QualityTier.HIGH)

    override fun saveDefault(quality: StreamQuality): Boolean = settings.saveStreamQuality(quality)

    override fun apply(choice: QualityChoice): Boolean = controller.setQuality(choice)
}
