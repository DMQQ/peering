package pl.dmq.peering.ui.wiring

import kotlinx.coroutines.CoroutineScope
import pl.dmq.peering.session.controller.ConnectTarget

/** Builds the session for a target, with the platform objects it owns. */
internal fun interface SessionOpener {
    fun open(target: ConnectTarget, scope: CoroutineScope): ActiveSession
}
