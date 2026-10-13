package pl.dmq.peering.ui.wiring

import pl.dmq.peering.feature.remote.HubCapabilities
import pl.dmq.peering.feature.remote.PictureState
import pl.dmq.peering.feature.remote.RemoteUiState
import pl.dmq.peering.feature.remote.SourcesFeatures
import pl.dmq.peering.session.connection.HostCapability
import pl.dmq.peering.session.controller.PictureState as SessionPictureState
import pl.dmq.peering.session.controller.SessionPhase
import pl.dmq.peering.session.controller.SessionUiState
import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.PixelSize

/** The remote screen's facts, from the session's published state and what the wiring knows about the host. */
internal fun remoteUiState(
    session: SessionUiState,
    picturePixels: PixelSize?,
    capabilities: HubCapabilities,
    relayMinutesLeft: Int?,
): RemoteUiState {
    val ready = session.phase as? SessionPhase.Ready
    val catalogue = session.catalogue
    val chosen = catalogue?.let { listOf(it.displays, it.applications, it.windows).flatten() }
        ?.firstOrNull { it.source == session.activeSource }
    val mosaic = (session.activeSource as? CaptureSource.Mosaic)?.layout
    return RemoteUiState(
        catalog = catalogue,
        chosenSource = session.activeSource,
        sourceTitle = if (session.activeSource is CaptureSource.Mosaic) null else chosen?.title,
        sourceBundleId = chosen?.bundleIdentifier,
        picturePixels = picturePixels,
        latencyMs = session.latencyMillis,
        path = ready?.path,
        pictureState = session.picture.toScreenPicture(),
        relayMinutesLeft = relayMinutesLeft,
        capabilities = capabilities,
        hostName = ready?.hostName,
        reconnecting = session.phase is SessionPhase.Reconnecting,
        hostClipboard = session.hostClipboard,
        sourcesFeatures = SourcesFeatures(
            windowControls = ready?.capabilities?.contains(HostCapability.MacControls) == true,
            virtualDisplays = ready?.capabilities?.contains(HostCapability.VirtualDisplayManagement) == true,
            desktops = ready?.capabilities?.contains(HostCapability.MacControls) == true,
        ),
        supportsMosaic = ready?.capabilities?.contains(HostCapability.Mosaic) == true,
        mosaic = mosaic,
        rememberedMosaic = session.rememberedMosaic,
        hostPointer = session.hostPointer,
        directPath = session.directPath,
        videoStream = session.videoStream,
        clipboardImages = ready?.capabilities?.contains(HostCapability.ClipboardImages) == true,
    )
}

internal fun SessionPictureState.toScreenPicture(): PictureState = when (this) {
    SessionPictureState.Connecting -> PictureState.WAITING
    SessionPictureState.Live, SessionPictureState.Fallback -> PictureState.LIVE
    SessionPictureState.Paused -> PictureState.PAUSED
    SessionPictureState.Stalled -> PictureState.STALLED
    is SessionPictureState.Failed -> PictureState.FAILED
}
