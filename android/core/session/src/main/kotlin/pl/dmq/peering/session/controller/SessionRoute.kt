package pl.dmq.peering.session.controller

import pl.dmq.peering.session.history.SessionRecord

/** How the picture and control reach the host, as the route pill shows it: straight over a network, or through the relay. */
enum class SessionRoute {
    Direct,
    Relay,
    ;

    companion object {
        fun of(path: SessionRecord.Path): SessionRoute = if (path == SessionRecord.Path.RELAY) Relay else Direct
    }
}

/** The route of the session, or the route it is expected to take while connecting. Null before a session starts and after it ends. */
val SessionUiState.route: SessionRoute?
    get() = when (val current = phase) {
        is SessionPhase.Ready -> SessionRoute.of(current.path)
        is SessionPhase.Connecting -> SessionRoute.of(current.path)
        else -> null
    }
