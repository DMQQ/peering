package pl.dmq.peering.ui.wiring

import android.view.Surface
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import pl.dmq.peering.feature.paywall.RelayAllowance
import pl.dmq.peering.feature.remote.ClipboardPort
import pl.dmq.peering.feature.remote.CommandSink
import pl.dmq.peering.feature.remote.HubCapabilities
import pl.dmq.peering.feature.remote.HubEntry
import pl.dmq.peering.feature.remote.MacroStore
import pl.dmq.peering.feature.remote.QualityPort
import pl.dmq.peering.feature.remote.RemoteModel
import pl.dmq.peering.feature.remote.StatusPillMemory
import pl.dmq.peering.feature.remote.RemoteUiState
import pl.dmq.peering.feature.remote.SurfaceListener
import pl.dmq.peering.feature.remote.relayMinutesLeft
import pl.dmq.peering.feature.settings.DevicePreferences
import pl.dmq.peering.session.controller.SessionController

/** The remote screen over the live session: its state, its input, and the picture's surface. */
internal class ControllerRemoteModel(
    private val controller: SessionController,
    private val picture: SurfacePicture,
    scope: CoroutineScope,
    override val quality: QualityPort,
    override val prefs: DevicePreferences,
    override val macros: MacroStore,
    relayAllowance: StateFlow<RelayAllowance>,
    private val onDisconnect: () -> Unit,
    private val onLeave: () -> Unit,
    private val onOpenHub: () -> Unit,
    private val onOpenPaywall: () -> Unit,
) : RemoteModel {
    override val statusPillMemory = StatusPillMemory()

    override val state: StateFlow<RemoteUiState> = combine(controller.state, picture.pixelSize, relayAllowance) { session, pixels, allowance ->
        remoteUiState(session, pixels, hubCapabilities(), relayMinutesLeft(allowance))
    }.stateIn(scope, SharingStarted.Eagerly, RemoteUiState.INITIAL)

    override val commands: CommandSink = CommandSink { controller.send(it) }

    // The hub is its own activity, so this screen's surface is destroyed while it is open and the stream restarts on return.
    override val surface: SurfaceListener = object : SurfaceListener by picture {
        override fun onSurfaceAvailable(surface: Surface) {
            picture.onSurfaceAvailable(surface)
            if (picture.surfaceReturnedWithoutKeyframe) controller.retryPicture()
        }
    }

    override val clipboard: ClipboardPort = object : ClipboardPort {
        override val history = controller.clipboardHistory.entries

        override fun sendImage(png: ByteArray) = controller.sendClipboardImage(png)

        override fun remove(id: Long) = controller.clipboardHistory.remove(id)

        override fun clear() = controller.clipboardHistory.clear()
    }

    override fun onHubEntry(entry: HubEntry) {
        when (entry) {
            HubEntry.HUB -> onOpenHub()
            HubEntry.DISCONNECT -> onDisconnect()
        }
    }

    override fun onStepAway() = onLeave()

    override fun onRetryPicture() {
        controller.retryPicture()
    }

    override fun onRelayUpgradeRequested() = onOpenPaywall()

    private fun hubCapabilities(): HubCapabilities =
        HubCapabilities(
            agentChat = controller.agentChat != null,
            fileBrowser = controller.files != null,
            terminal = controller.terminals != null,
        )
}
