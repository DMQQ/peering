package pl.dmq.peering.feature.remote

import kotlinx.coroutines.flow.StateFlow
import pl.dmq.peering.feature.settings.DevicePreferences

/** What the remote screen needs from the session. The session side implements it; the screen never talks to the wire. */
interface RemoteModel {
    val state: StateFlow<RemoteUiState>

    /** Where the user's input goes. */
    val commands: CommandSink

    /** Receives the picture's surface, for the decoder to draw into. */
    val surface: SurfaceListener

    /** The picture quality the Settings panel reads and changes. */
    val quality: QualityPort

    /** Whether this session has already opened its status pill by itself. */
    val statusPillMemory: StatusPillMemory

    /** The choices Settings keeps: interaction, fit or fill, keyboard mode, closing panels, device name. */
    val prefs: DevicePreferences

    /** The clipboard history and the pictures the Clipboard panel moves. */
    val clipboard: ClipboardPort

    /** The shortcuts the user added. */
    val macros: MacroStore

    /** A hub entry the remote screen does not open itself: Agents, Files, Terminal or Disconnect. */
    fun onHubEntry(entry: HubEntry)

    /** Leaves the session screen and keeps the session running, as the Connect chip does. */
    fun onStepAway()

    /** The picture stalled or failed and the user asked for it again. */
    fun onRetryPicture()

    /** A quality the session cannot stream without more relay time was picked: the paywall opens. */
    fun onRelayUpgradeRequested()
}
