package pl.dmq.peering.ui.wiring

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import pl.dmq.peering.feature.remote.CommandSink
import pl.dmq.peering.feature.remote.HubCapabilities
import pl.dmq.peering.feature.remote.HubEntry
import pl.dmq.peering.feature.remote.InputMode
import pl.dmq.peering.feature.remote.QualityPort
import pl.dmq.peering.feature.remote.RemoteModel
import pl.dmq.peering.feature.remote.RemoteUiState
import pl.dmq.peering.feature.remote.SurfaceListener
import pl.dmq.peering.session.controller.SessionController
import pl.dmq.peering.ui.nav.SessionRoute

/** The remote screen over the live session: its state, its input, and the picture's surface. */
internal class ControllerRemoteModel(
    private val controller: SessionController,
    private val picture: SurfacePicture,
    scope: CoroutineScope,
    override val quality: QualityPort,
    private val onOpen: (SessionRoute) -> Unit,
) : RemoteModel {
    override val state: StateFlow<RemoteUiState> = combine(controller.state, picture.pixelSize) { session, pixels ->
        remoteUiState(session, pixels, hubCapabilities(), InputMode.TRACKPAD)
    }.stateIn(scope, SharingStarted.Eagerly, RemoteUiState.INITIAL)

    override val commands: CommandSink = CommandSink { controller.send(it) }

    override val surface: SurfaceListener = picture

    override fun onHubEntry(entry: HubEntry) {
        when (entry) {
            HubEntry.AGENTS -> onOpen(SessionRoute.AGENTS)
            HubEntry.FILES -> onOpen(SessionRoute.FILES)
            HubEntry.DISCONNECT -> controller.disconnect()
            HubEntry.SOURCES, HubEntry.QUALITY -> Unit
        }
    }

    override fun onRelayUpgradeRequested() = onOpen(SessionRoute.PAYWALL)

    private fun hubCapabilities(): HubCapabilities =
        HubCapabilities(agentChat = controller.agentChat != null, fileBrowser = controller.files != null)
}
