package pl.dmq.peering.session.controller

import pl.dmq.peering.session.clipboard.ClipboardContent
import pl.dmq.peering.wire.CaptureCatalog
import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.MosaicLayout
import pl.dmq.peering.wire.QualityTier

/** Everything the session screen shows. Changes are published as one value, so a screen never sees half an update. */
data class SessionUiState(
    val phase: SessionPhase = SessionPhase.Idle,
    val catalogue: CaptureCatalog? = null,
    val activeSource: CaptureSource? = null,
    /** The last mosaic asked for in this session, which the panel offers a way back to. */
    val rememberedMosaic: MosaicLayout? = null,
    val latencyMillis: Int? = null,
    val picture: PictureState = PictureState.Connecting,
    val notice: String? = null,
    /** What the computer's clipboard held when last asked, or null before it answered. */
    val hostClipboard: ClipboardContent? = null,
    val qualityCeiling: QualityTier = QualityTier.HIGH,
)
