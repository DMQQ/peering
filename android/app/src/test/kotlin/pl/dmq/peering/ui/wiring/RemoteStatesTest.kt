package pl.dmq.peering.ui.wiring

import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.feature.remote.HubCapabilities
import pl.dmq.peering.feature.remote.InputMode
import pl.dmq.peering.feature.remote.PictureState
import pl.dmq.peering.session.controller.PictureFailure
import pl.dmq.peering.session.controller.PictureState as SessionPictureState
import pl.dmq.peering.session.controller.SessionPhase
import pl.dmq.peering.session.controller.SessionUiState
import pl.dmq.peering.session.history.SessionRecord
import pl.dmq.peering.wire.PixelSize

class RemoteStatesTest {
    private val pixels = PixelSize(1512.0, 982.0)
    private val capabilities = HubCapabilities(agentChat = true, fileBrowser = false)

    @Test
    fun aReadySessionCarriesItsPathAndLatency() {
        val session = SessionUiState(
            phase = SessionPhase.Ready("Studio", emptySet(), SessionRecord.Path.DIRECT),
            latencyMillis = 42,
            picture = SessionPictureState.Live,
        )

        val state = remoteUiState(session, pixels, capabilities, InputMode.TRACKPAD, relayMinutesLeft = 12)

        assertEquals(SessionRecord.Path.DIRECT, state.path)
        assertEquals(42, state.latencyMs)
        assertEquals(PictureState.LIVE, state.pictureState)
        assertEquals(pixels, state.picturePixels)
        assertEquals(capabilities, state.capabilities)
        assertEquals(12, state.relayMinutesLeft)
        assertEquals("Studio", state.hostName)
        assertEquals(false, state.reconnecting)
    }

    @Test
    fun aSessionThatIsNotReadyHasNoPath() {
        val session = SessionUiState(phase = SessionPhase.Reconnecting(1), picture = SessionPictureState.Connecting)

        val state = remoteUiState(session, null, HubCapabilities.NONE, InputMode.TRACKPAD, relayMinutesLeft = null)

        assertEquals(null, state.path)
        assertEquals(true, state.reconnecting)
        assertEquals(PictureState.WAITING, state.pictureState)
    }

    @Test
    fun thePictureStatesMapOntoTheScreensThreeStates() {
        assertEquals(PictureState.WAITING, SessionPictureState.Connecting.toScreenPicture())
        assertEquals(PictureState.LIVE, SessionPictureState.Live.toScreenPicture())
        assertEquals(PictureState.LIVE, SessionPictureState.Fallback.toScreenPicture())
        assertEquals(PictureState.PAUSED, SessionPictureState.Paused.toScreenPicture())
        assertEquals(PictureState.STALLED, SessionPictureState.Stalled.toScreenPicture())
        assertEquals(PictureState.FAILED, SessionPictureState.Failed(PictureFailure.Dropped).toScreenPicture())
    }
}
