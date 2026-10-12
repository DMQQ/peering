package pl.dmq.peering.session.controller

import pl.dmq.peering.wire.CaptureCatalog
import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.QualityTier

/** Everything the session screen shows. Changes are published as one value, so a screen never sees half an update. */
data class SessionUiState(
    val phase: SessionPhase = SessionPhase.Idle,
    val catalogue: CaptureCatalog? = null,
    val activeSource: CaptureSource? = null,
    val latencyMillis: Int? = null,
    val picture: PictureState = PictureState.Connecting,
    val notice: String? = null,
    /** The text the computer's clipboard held when last asked, or null. */
    val hostClipboard: String? = null,
    val qualityCeiling: QualityTier = QualityTier.HIGH,
)
