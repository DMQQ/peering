package pl.dmq.peering.ui.nav

import pl.dmq.peering.feature.sessionmode.SessionMode
import pl.dmq.peering.feature.sessionmode.SessionModeMemory
import pl.dmq.peering.session.controller.SessionPhase

/** The computer's picture as the session controller has it: on unless the host accepted a pause. */
internal interface PictureSwitch {
    val pictureOn: Boolean

    /** False when the change could not be sent. */
    fun setPictureEnabled(enabled: Boolean): Boolean
}

/** Where a session's screens go: [show] presents a route, [openHub] opens the hub's own activity. */
internal class SessionNavigation(
    val route: () -> SessionRoute,
    val show: (SessionRoute) -> Unit,
    val openHub: () -> Unit,
)

/**
 * Which mode a session is in and how it changes. The first time a computer is ready the person chooses, and after that
 * the session opens in the mode it was last used in. Leaving the screen mode pauses the picture and entering it brings it back.
 * Every way back to the remote screen goes through here, so arriving there always means the screen mode with the picture on.
 */
internal class SessionModes(
    private val hostId: String?,
    private val memory: SessionModeMemory,
    private val picture: PictureSwitch,
    private val workspaceOffered: () -> Boolean,
    private val navigation: SessionNavigation,
    mode: SessionMode?,
    private val setMode: (SessionMode) -> Unit,
) {
    var mode: SessionMode? = mode
        private set

    val available: List<SessionMode> get() = SessionMode.available(workspaceOffered())

    /** A session became ready. The first time it opens in the remembered mode or asks; a later link is the controller's to pause again. */
    fun ready(asksEveryTime: Boolean, firstTime: Boolean) {
        if (!firstTime) return
        memory.startingMode(hostId, asksEveryTime, available)?.let(::choose) ?: ask()
    }

    fun choose(next: SessionMode) {
        memory.remember(hostId, next)
        enter(next)
    }

    fun ask() = navigation.show(SessionRoute.PICKER)

    fun back() {
        when (navigation.route()) {
            SessionRoute.REMOTE -> Unit
            SessionRoute.DOCK -> ask()
            SessionRoute.PICKER -> if (mode == SessionMode.REMOTE) navigation.show(SessionRoute.DOCK) else enter(SessionMode.SCREEN)
            SessionRoute.PAYWALL -> enter(SessionMode.SCREEN)
        }
    }

    private fun enter(next: SessionMode) {
        mode = next
        setMode(next)
        matchPicture()
        when (next) {
            SessionMode.SCREEN -> navigation.show(SessionRoute.REMOTE)
            SessionMode.REMOTE -> navigation.show(SessionRoute.DOCK)
            SessionMode.WORKSPACE -> {
                navigation.show(SessionRoute.PICKER)
                navigation.openHub()
            }
        }
    }

    // Offline, the controller keeps the choice for the next link. A host that cannot pause keeps its picture on, and
    // a mode without one simply does not show it.
    private fun matchPicture() {
        val wanted = mode?.needsPicture ?: return
        if (wanted != picture.pictureOn) picture.setPictureEnabled(wanted)
    }
}

/** Only a session that reached ready has a mode to choose. */
internal fun SessionPhase.isReady(): Boolean = this is SessionPhase.Ready
