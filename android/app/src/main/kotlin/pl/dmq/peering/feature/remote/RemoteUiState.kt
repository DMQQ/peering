package pl.dmq.peering.feature.remote

import pl.dmq.peering.session.history.SessionRecord
import pl.dmq.peering.wire.CaptureCatalog
import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.PixelSize

/** The session facts the remote screen shows. The session side publishes a new value whenever one changes. */
data class RemoteUiState(
    val catalog: CaptureCatalog?,
    val chosenSource: CaptureSource?,
    /** Pixel size of the chosen source, which the picture is fitted to. Null until the catalogue says it. */
    val picturePixels: PixelSize?,
    val latencyMs: Int?,
    val path: SessionRecord.Path?,
    val pictureState: PictureState,
    /** Relay minutes left today, or null when the plan has no limit. */
    val relayMinutesLeft: Int?,
    val capabilities: HubCapabilities,
    val inputMode: InputMode,
) {
    companion object {
        val INITIAL = RemoteUiState(
            catalog = null,
            chosenSource = null,
            picturePixels = null,
            latencyMs = null,
            path = null,
            pictureState = PictureState.WAITING,
            relayMinutesLeft = null,
            capabilities = HubCapabilities.NONE,
            inputMode = InputMode.TRACKPAD,
        )
    }
}
