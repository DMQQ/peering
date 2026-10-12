package pl.dmq.peering.feature.remote

import pl.dmq.peering.session.clipboard.ClipboardContent
import pl.dmq.peering.session.history.SessionRecord
import pl.dmq.peering.wire.CaptureCatalog
import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.PixelSize

/** The session facts the remote screen shows. The session side publishes a new value whenever one changes. */
data class RemoteUiState(
    val catalog: CaptureCatalog?,
    val chosenSource: CaptureSource?,
    /** The title of the chosen source: a window's title or a display's name. Null until the catalogue says it. */
    val sourceTitle: String?,
    /** The chosen source's application, which picks the shortcut set for the application on screen. */
    val sourceBundleId: String?,
    /** Pixel size of the chosen source, which the picture is fitted to. Null until the catalogue says it. */
    val picturePixels: PixelSize?,
    val latencyMs: Int?,
    val path: SessionRecord.Path?,
    val pictureState: PictureState,
    /** Relay minutes left today, or null when the plan has no limit. */
    val relayMinutesLeft: Int?,
    val capabilities: HubCapabilities,
    /** The computer's name while the session is ready, else null. */
    val hostName: String?,
    val reconnecting: Boolean,
    /** What the computer's clipboard held when last asked, or null. */
    val hostClipboard: ClipboardContent?,
    /** Whether the computer declared that it takes pictures on its clipboard. */
    val clipboardImages: Boolean,
) {
    companion object {
        val INITIAL = RemoteUiState(
            catalog = null,
            chosenSource = null,
            sourceTitle = null,
            sourceBundleId = null,
            picturePixels = null,
            latencyMs = null,
            path = null,
            pictureState = PictureState.WAITING,
            relayMinutesLeft = null,
            capabilities = HubCapabilities.NONE,
            hostName = null,
            reconnecting = false,
            hostClipboard = null,
            clipboardImages = false,
        )
    }
}
