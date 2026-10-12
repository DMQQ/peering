package pl.dmq.peering.ui.wiring

import pl.dmq.peering.feature.remote.HubCapabilities
import pl.dmq.peering.feature.remote.PictureState
import pl.dmq.peering.feature.remote.RemoteUiState
import pl.dmq.peering.session.clipboard.ClipboardContent
import pl.dmq.peering.session.controller.PictureState as SessionPictureState
import pl.dmq.peering.session.controller.SessionPhase
import pl.dmq.peering.session.controller.SessionUiState
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
    return RemoteUiState(
        catalog = catalogue,
        chosenSource = session.activeSource,
        sourceTitle = chosen?.title,
        sourceBundleId = chosen?.bundleIdentifier,
        picturePixels = picturePixels,
        latencyMs = session.latencyMillis,
        path = ready?.path,
        pictureState = session.picture.toScreenPicture(),
        relayMinutesLeft = relayMinutesLeft,
        capabilities = capabilities,
        hostName = ready?.hostName,
        reconnecting = session.phase is SessionPhase.Reconnecting,
        hostClipboard = (session.hostClipboard as? ClipboardContent.Text)?.text,
    )
}

internal fun SessionPictureState.toScreenPicture(): PictureState = when (this) {
    SessionPictureState.Connecting -> PictureState.WAITING
    SessionPictureState.Live, SessionPictureState.Fallback -> PictureState.LIVE
    SessionPictureState.Paused -> PictureState.PAUSED
    SessionPictureState.Stalled -> PictureState.STALLED
    is SessionPictureState.Failed -> PictureState.FAILED
}
