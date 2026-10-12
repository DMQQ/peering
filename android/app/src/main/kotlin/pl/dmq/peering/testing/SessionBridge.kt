package pl.dmq.peering.testing

import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberUpdatedState
import pl.dmq.peering.session.controller.SessionPhase
import pl.dmq.peering.ui.nav.SessionRoute
import pl.dmq.peering.ui.wiring.ActiveSession

private const val HOME = "~"

/** The session's phase, picture, files, terminals and agents, and the hub and file commands that go through the same handlers as the buttons. */
@Composable
internal fun SessionBridge(
    active: ActiveSession,
    route: SessionRoute,
    openHub: () -> Unit,
    setRoute: (SessionRoute) -> Unit,
) {
    val shown = rememberUpdatedState(route)
    BridgeRegistration("session", active) {
        val controller = active.controller
        TestBridge.Slot(
            state = {
                val session = controller.state.value
                val phase = session.phase
                val files = controller.files?.state?.value
                val listing = files?.listing
                mapOf(
                    "sessionRoute" to shown.value.name,
                    "phase" to phase.javaClass.simpleName,
                    "failure" to (phase as? SessionPhase.Failed)?.reason?.javaClass?.simpleName,
                    "hostName" to (phase as? SessionPhase.Ready)?.hostName,
                    "routePath" to when (phase) {
                        is SessionPhase.Ready -> phase.path.name
                        is SessionPhase.Connecting -> phase.path.name
                        else -> null
                    },
                    "picture" to session.picture.javaClass.simpleName.uppercase(),
                    "filesPath" to listing?.path,
                    "filesEntries" to listing?.visibleEntries?.size,
                    "filesLoading" to files?.listingLoading,
                    "filesFailure" to files?.browseFailure,
                    "previewPath" to files?.preview?.path,
                    "previewComplete" to files?.preview?.isComplete,
                    "terminalCards" to controller.terminals?.state?.value?.tabs?.size,
                    "agentSessions" to controller.agentChat?.state?.value?.sessions?.size,
                    "agentsResumable" to controller.agentChat?.resumable?.value?.size,
                )
            },
            actions = mapOf(
                "hub" to { arg -> hub(arg, openHub) },
                "terminal-list" to { hub("terminals", openHub) },
                "files-open" to { arg -> controller.files?.list(arg?.takeUnless { it == HOME }) },
                "files-preview" to { arg -> arg?.let { controller.files?.preview(it) } },
            ),
        )
    }
}

/** The hub is its own activity: a tab command opens it when it is not up, and close finishes it. */
private fun hub(arg: String?, openHub: () -> Unit) {
    if (arg == "close") {
        TestBridge.invoke("hub-close", null)
        return
    }
    if (!TestBridge.invoke("hub-tab", arg)) {
        openHub()
        TestBridge.invokeWhenAvailable("hub-tab", arg)
    }
}
