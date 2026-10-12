package pl.dmq.peering.feature.remote

import kotlinx.coroutines.flow.StateFlow

/** What the remote screen needs from the session. The session side implements it; the screen never talks to the wire. */
interface RemoteModel {
    val state: StateFlow<RemoteUiState>

    /** Where the user's input goes. */
    val commands: CommandSink

    /** Receives the picture's surface, for the decoder to draw into. */
    val surface: SurfaceListener

    /** The picture quality the sheet reads and changes. */
    val quality: QualityPort

    /** A hub entry the remote screen does not open itself: Agents, Files or Disconnect. */
    fun onHubEntry(entry: HubEntry)

    /** The picture stalled or failed and the user asked for it again. */
    fun onRetryPicture()

    /** A quality the session cannot stream without more relay time was picked: the paywall opens. */
    fun onRelayUpgradeRequested()
}
