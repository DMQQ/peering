package pl.dmq.peering.feature.remote

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import pl.dmq.peering.feature.settings.StreamQuality
import pl.dmq.peering.wire.QualityTier

/** The quality sheet as drawn: the choice the device stores, the ceiling the session is held to, and a save that failed. */
data class QualitySheetUi(
    val selected: StreamQuality,
    val ceiling: QualityTier,
    val saveFailed: Boolean,
)

/**
 * Applies a quality pick to the live session and stores it as the default, so Settings and the sheet show the same
 * setting. A pick above the ceiling is not applied: [onNeedsUpgrade] is called instead, and nothing is stored.
 */
class QualitySheetPresenter(
    private val port: QualityPort,
    scope: CoroutineScope,
    private val onNeedsUpgrade: () -> Unit,
) {
    private val saveFailed = MutableStateFlow(false)

    val ui: StateFlow<QualitySheetUi> = combine(port.stored, port.ceiling, saveFailed) { selected, ceiling, failed ->
        QualitySheetUi(selected, ceiling, failed)
    }.stateIn(scope, SharingStarted.Eagerly, QualitySheetUi(StreamQuality.Auto, QualityTier.HIGH, saveFailed = false))

    fun choose(quality: StreamQuality) {
        when (val decision = QualityDecision.of(quality, port.ceiling.value)) {
            QualityDecision.NeedsUpgrade -> onNeedsUpgrade()
            is QualityDecision.Apply -> {
                if (!port.saveDefault(quality)) {
                    saveFailed.value = true
                    return
                }
                saveFailed.value = false
                port.apply(decision.choice)
            }
        }
    }
}
