package pl.dmq.peering.ui.wiring

import pl.dmq.peering.feature.remote.HubCapabilities
import pl.dmq.peering.feature.remote.InputMode
import pl.dmq.peering.feature.remote.PictureState
import pl.dmq.peering.feature.remote.RemoteUiState
import pl.dmq.peering.session.controller.PictureState as SessionPictureState
import pl.dmq.peering.session.controller.SessionPhase
import pl.dmq.peering.session.controller.SessionUiState
import pl.dmq.peering.wire.PixelSize

/** The remote screen's facts, from the session's published state and what the wiring knows about the host. */
internal fun remoteUiState(
    session: SessionUiState,
    picturePixels: PixelSize?,
    capabilities: HubCapabilities,
    inputMode: InputMode,
): RemoteUiState {
    val ready = session.phase as? SessionPhase.Ready
    return RemoteUiState(
        catalog = session.catalogue,
        chosenSource = session.activeSource,
        picturePixels = picturePixels,
        latencyMs = session.latencyMillis,
        path = ready?.path,
        pictureState = session.picture.toScreenPicture(),
        relayMinutesLeft = null,
        capabilities = capabilities,
        inputMode = inputMode,
    )
}

internal fun SessionPictureState.toScreenPicture(): PictureState = when (this) {
    SessionPictureState.Connecting -> PictureState.WAITING
    SessionPictureState.Live, SessionPictureState.Fallback -> PictureState.LIVE
    SessionPictureState.Paused -> PictureState.PAUSED
}
