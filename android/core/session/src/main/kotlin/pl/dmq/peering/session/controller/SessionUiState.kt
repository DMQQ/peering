package pl.dmq.peering.session.controller

import pl.dmq.peering.session.clipboard.ClipboardContent
import pl.dmq.peering.wire.CaptureCatalog
import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.MosaicLayout
import pl.dmq.peering.session.relay.DirectPathState
import pl.dmq.peering.wire.QualityTier
import pl.dmq.peering.wire.VideoStreamConfig

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
    /** The computer's own report of its pointer, or null before one arrived. */
    val hostPointer: HostPointer? = null,
    /** The computer's focus: a text field or not. Null before it said. */
    val hostTextFocus: HostTextFocus? = null,
    /** What the focused field holds, or null before the computer said or after the focus moved. */
    val hostField: HostField? = null,
    val qualityCeiling: QualityTier = QualityTier.HIGH,
    /** How the attempt at a direct path stands, or null when this link makes none (a session on the local network). */
    val directPath: DirectPathState? = null,
    /** The codec and size of the stream last configured, or null before the computer sent one. */
    val videoStream: VideoStreamConfig? = null,
)
