package pl.dmq.peering.feature.remote

import pl.dmq.peering.session.clipboard.ClipboardContent
import pl.dmq.peering.session.controller.HostField
import pl.dmq.peering.session.controller.HostPointer
import pl.dmq.peering.session.controller.HostTextFocus
import pl.dmq.peering.session.history.SessionRecord
import pl.dmq.peering.session.relay.DirectPathState
import pl.dmq.peering.wire.CaptureCatalog
import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.MosaicLayout
import pl.dmq.peering.wire.PixelSize
import pl.dmq.peering.wire.VideoStreamConfig

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
    /** What the computer can do beyond showing its screen, which the Apps panel offers only when it can. */
    val sourcesFeatures: SourcesFeatures = SourcesFeatures(),
    /** Whether the computer declared that it can compose a mosaic. A Windows host does not. */
    val supportsMosaic: Boolean = false,
    /** The mosaic on screen, or null while a single source is. */
    val mosaic: MosaicLayout? = null,
    /** The last mosaic asked for, which the panel offers a way back to. */
    val rememberedMosaic: MosaicLayout? = null,
    /** Whether the computer's focus is on a text field, or null before it said. */
    val hostTextFocus: HostTextFocus? = null,
    /** What the focused text field holds, or null before the computer said or after the focus moved. */
    val hostField: HostField? = null,
    /** The computer's own report of where its pointer is, which the cursor glyph follows. */
    val hostPointer: HostPointer? = null,
    /** How the attempt at a direct path stands, or null when this session makes none. */
    val directPath: DirectPathState? = null,
    /** The stream the computer last configured, or null before it did. */
    val videoStream: VideoStreamConfig? = null,
) {
    val showsMosaic: Boolean get() = chosenSource is CaptureSource.Mosaic

    val canReturnToMosaic: Boolean get() = supportsMosaic && !showsMosaic && rememberedMosaic != null

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
